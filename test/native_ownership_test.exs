defmodule LibTmux.NativeOwnershipTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.Processes
  alias LibTmux.Transport.Native

  @moduletag :integration
  @moduletag reason:
               "Qualifies native protocol faults, blocked I/O and Linux process-tree retirement"

  @vm_flags ~c"+S 1:1 +A 1 +SDcpu 1 +SDio 1"

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ltx-vm-#{System.pid()}-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {output, status} =
      System.cmd(
        System.find_executable("erlc"),
        ["-Werror", "-o", root, Path.join(__DIR__, "support/libtmux_io_vm.erl")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    %{beams: root}
  end

  for mode <- ["owner", "vm"] do
    test "#{mode} death retires helper descendants while an unrelated process survives", c do
      unrelated = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :exit_status])
      {:os_pid, unrelated_pid} = Port.info(unrelated, :os_pid)
      unrelated_identity = Processes.identity!(unrelated_pid)

      vm =
        Port.open({:spawn_executable, System.find_executable("erl")}, [
          :binary,
          :exit_status,
          {:line, 256},
          {:env,
           [
             {~c"ERL_FLAGS", @vm_flags},
             {~c"LIBTMUX_IO_SPIKE", String.to_charlist(Native.executable())}
           ]},
          {:args,
           ["-noshell", "-pa", c.beams, "-s", "libtmux_io_vm", "run"] ++ extra(unquote(mode))}
        ])

      {:os_pid, vm_pid} = Port.info(vm, :os_pid)

      try do
        assert_receive {^vm, {:data, {:eol, line}}}, 950

        processes =
          line |> String.split() |> Enum.map(&Processes.identity!(String.to_integer(&1)))

        assert length(processes) == 3

        case unquote(mode) do
          "owner" ->
            true = Port.command(vm, "kill\n")
            assert_receive {^vm, {:data, {:eol, "owner-down"}}}, 750
            assert Port.info(vm), "the VM died during the owner-only test"

          "vm" ->
            {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(vm_pid)])
            assert_receive {^vm, {:exit_status, status}}, 750
            assert status == 137
        end

        assert Processes.await_exit(processes) == :ok,
               "owned processes survived owner or VM death"

        assert Processes.alive?(unrelated_identity), "an unrelated process was killed"
      after
        System.cmd("kill", ["-KILL", Integer.to_string(vm_pid)], stderr_to_stdout: true)
        Port.close(unrelated)
        assert Processes.await_exit([unrelated_identity]) == :ok
      end
    end
  end

  test "a suspended BEAM owner receives only its credited flood bytes" do
    parent = self()
    helper = Native.executable()
    string = fn value -> <<byte_size(value)::16, value::binary>> end

    {owner, monitor} =
      spawn_monitor(fn ->
        port = Port.open({:spawn_executable, helper}, [:binary, :exit_status, {:packet, 2}])
        args = ["/bin/sh", "-c", "yes yyyyyyyy >&2 & exec yes xxxxxxxx"]

        true =
          Port.command(port, [
            <<?O, 3, 0, 0::32>>,
            string.(File.cwd!()),
            <<length(args)::16>>,
            Enum.map(args, string),
            <<0::16>>
          ])

        child =
          receive do
            {^port, {:data, <<?S, child::32>>}} -> child
          after
            750 -> raise "helper did not launch"
          end

        true = Port.command(port, <<?R, 1, 8192::16>>)
        true = Port.command(port, <<?R, 2, 8192::16>>)

        streams =
          for _ <- 1..2 do
            receive do
              {^port, {:data, <<?D, stream, bytes::binary>>}} ->
                true = byte_size(bytes) <= 8192
                stream
            after
              750 -> raise "flood did not produce both streams"
            end
          end

        [1, 2] = Enum.sort(streams)
        :erlang.garbage_collect()
        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:ready, self(), port, pid, child})

        receive do
          :finish -> :ok
        end

        retire(port)
      end)

    try do
      assert_receive {:ready, ^owner, port, helper_pid, child_pid}, 950
      helper = Processes.identity!(helper_pid)
      child = Processes.identity!(child_pid)

      true = :erlang.suspend_process(owner)
      true = Port.command(port, <<?R, 1, 8192::16>>)
      true = Port.command(port, <<?R, 2, 8192::16>>)
      true = Port.command(port, "Q")

      assert Processes.await_exit([child]) == :ok, "producer did not retire"

      {:message_queue_len, messages} = Process.info(owner, :message_queue_len)
      {:binary, binaries} = Process.info(owner, :binary)

      bytes =
        binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reduce(0, fn {_, n, _}, sum -> sum + n end)

      assert messages <= 4
      assert bytes <= 65_536
      true = :erlang.resume_process(owner)
      send(owner, :finish)

      assert Processes.await_exit([helper]) == :ok, "helper did not retire"
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 750
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  defp extra("owner"), do: ["-extra", "owner"]
  defp extra("vm"), do: []

  defp retire(port) do
    receive do
      {^port, {:data, <<?E, _reason, _status::32>>}} ->
        true = Port.command(port, "T")

        receive do
          {^port, {:exit_status, 0}} -> :ok
        after
          750 -> raise "acknowledged helper did not exit"
        end

      {^port, {:data, _bytes}} ->
        retire(port)
    after
      750 -> raise "helper did not prove retirement"
    end
  end
end
