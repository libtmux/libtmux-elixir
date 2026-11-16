defmodule LibTmux.NativeContractTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.{Child, HelperPeer, Processes}
  alias LibTmux.Transport.Native

  @moduletag :integration
  @moduletag reason: "Qualifies the private helper protocol, credits and retirement under faults"

  @pause [:hold]
  @ignore_term [:ignore_term, :hold]
  @flood [{:flood, :stdout, "xxxxxxxx"}, :hold]

  # A child that outlives its parent: it detaches a grandchild in its own
  # session that ignores SIGTERM and reports its pid on stdout. The child itself
  # keeps running as the direct child.
  @detached [{:detach, [:ignore_term, :pid, :hold]}, :hold]

  setup_all do
    Child.start_ms()

    directory =
      Path.join(
        System.tmp_dir!(),
        "ltx-contract-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    # A helper whose stdout pipe holds one page, so a reader that stops reading stalls it.
    source = File.read!(Path.join(__DIR__, "../c_src/owned_io.c"))
    needle = "    signal(SIGPIPE, SIG_IGN);\n"
    true = String.contains?(source, needle)

    patched =
      String.replace(source, needle, needle <> "    fcntl(STDOUT_FILENO, F_SETPIPE_SZ, 4096);\n",
        global: false
      )

    input = Path.join(directory, "owned_io.c")
    small = Path.join(directory, "owned_io_small_pipe")
    File.write!(input, patched)
    compiler = System.find_executable("cc") || raise "native integration requires a C11 compiler"

    assert {"", 0} =
             System.cmd(
               compiler,
               ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", input, "-o", small],
               stderr_to_stdout: true
             )

    %{directory: directory, small_pipe_helper: small}
  end

  test "stdout, stderr and the exit status stay separate bytes" do
    peer =
      HelperPeer.start(Child.argv([{:stdout, <<"out", 0, 255>>}, {:stderr, "err"}, {:exit, 7}]))

    {output, terminal} = HelperPeer.drain(peer)

    assert output == %{1 => <<"out", 0, 255>>, 2 => "err"}
    assert terminal == <<?E, 0, 7::32>>
  end

  test "the helper outlives its terminal frame until the owner acknowledges it" do
    peer = HelperPeer.start(["/bin/true"])
    {:ok, helper} = {:ok, Processes.identity!(peer.os_pid)}
    HelperPeer.grant(peer, 1)
    HelperPeer.grant(peer, 2)
    wait_for_terminal(peer)

    assert HelperPeer.silent?(peer, 20), "the helper exited or spoke before the acknowledgement"
    assert Processes.alive?(helper)

    # Credits and cancellation the owner already admitted may trail the proof.
    HelperPeer.grant(peer, 1)
    HelperPeer.send_frame(peer, "Q")
    HelperPeer.finish(peer)
  end

  test "a missing acknowledgement fails the helper instead of leaking it" do
    peer = HelperPeer.start(["/bin/true"])
    HelperPeer.grant(peer, 1)
    HelperPeer.grant(peer, 2)
    wait_for_terminal(peer)

    assert HelperPeer.exit_status(peer, 950) == 124
  end

  test "output moves only against credit and a write that cannot finish is partial" do
    flood = [{:flood, :stderr, "yyyyyyyy"}, {:flood, :stdout, "xxxxxxxx"}, :hold]
    peer = HelperPeer.start(Child.argv(flood), stdin: true)
    HelperPeer.grant(peer, 1)
    HelperPeer.grant(peer, 2)
    first = [HelperPeer.receive_frame(peer), HelperPeer.receive_frame(peer)]

    assert first |> Enum.map(fn <<_, stream, _::binary>> -> stream end) |> Enum.sort() == [1, 2]
    assert Enum.all?(first, &(match?(<<?D, _::binary>>, &1) and byte_size(&1) <= 8194))
    assert HelperPeer.silent?(peer, 50), "output arrived without credit"

    HelperPeer.write(peer, 1, :binary.copy("a", 4096))
    assert HelperPeer.receive_frame(peer) == <<?A, 1::32, 4096::16, 0>>

    # Nothing reads the child's stdin, so the next write stops at the pipe's capacity.
    HelperPeer.write(peer, 2, :binary.copy("b", 8192))
    assert HelperPeer.silent?(peer, 50), "a blocked write completed"
    HelperPeer.send_frame(peer, "Q")
    {acknowledgements, terminal} = collect_until_terminal(peer, [])
    HelperPeer.finish(peer)

    assert <<?A, 2::32, 4096::16, 1>> in acknowledgements
    assert <<?E, 1, _::32>> = terminal
  end

  test "cancellation retires a detached descendant that ignores SIGTERM" do
    {peer, grandchild} = detached()
    HelperPeer.cancel(peer)

    assert Processes.await_exit([grandchild], 0) == :ok
  end

  test "parent EOF retires a detached descendant without an acknowledgement" do
    {peer, grandchild} = detached()
    helper = Processes.identity!(peer.os_pid)
    HelperPeer.close(peer)

    assert Processes.await_exit([helper]) == :ok
    assert Processes.await_exit([grandchild], 0) == :ok
  end

  test "a child that ignores SIGTERM is killed at its deadline" do
    peer = HelperPeer.start(Child.argv(@ignore_term), timeout: Child.deadline(80))

    assert HelperPeer.receive_frame(peer) == <<?E, 2, 137::32>>
    HelperPeer.finish(peer)
  end

  test "a write after the child exited is refused with a failed acknowledgement" do
    program = [:read, {:stdout, "exit"}, {:exit, 7}]
    peer = HelperPeer.start(Child.argv(program), timeout: 0, stdin: true)
    child = Processes.identity!(peer.pid)

    HelperPeer.grant(peer, 1)
    HelperPeer.write(peer, 1, "g")
    frames = [HelperPeer.receive_frame(peer), HelperPeer.receive_frame(peer)]
    assert <<?D, 1, "exit">> in frames
    assert Processes.await_exit([child]) == :ok

    HelperPeer.write(peer, 2, "late")
    assert HelperPeer.receive_frame(peer) == <<?A, 2::32, 0::16, 1>>
    HelperPeer.send_frame(peer, "C")
    assert HelperPeer.receive_frame(peer) == "C"
    {output, terminal} = HelperPeer.drain(peer)

    assert output == %{1 => "", 2 => ""}
    assert terminal == <<?E, 0, 7::32>>
  end

  test "malformed headers, a missing cwd and a missing program fail without skipping the acknowledgement" do
    cwd_failure = HelperPeer.open_frame(Child.argv(@pause), cwd: "/missing-cwd")
    exec_failure = HelperPeer.open_frame(["/missing-executable"], timeout: 500)

    for frame <- [
          <<0, 1, ?X>>,
          <<0, 0>>,
          <<32_769::16>>,
          with_header(cwd_failure),
          with_header(exec_failure)
        ] do
      peer = HelperPeer.bare()
      helper = Processes.identity!(peer.os_pid)
      HelperPeer.send_raw(peer, frame)

      assert <<?F, _::binary>> = HelperPeer.receive_frame(peer)
      HelperPeer.send_frame(peer, "Q")
      assert Processes.alive?(helper), "an invalid header bypassed the terminal acknowledgement"
      assert HelperPeer.silent?(peer, 20)
      HelperPeer.finish(peer)
    end
  end

  test "a second credit for a stream that still holds one is a protocol failure" do
    peer = HelperPeer.start(Child.argv(@pause))
    HelperPeer.grant(peer, 1)
    HelperPeer.grant(peer, 1)

    assert <<?F, 1, _::binary>> = HelperPeer.receive_frame(peer)
    HelperPeer.finish(peer)
  end

  test "a startup that races cancellation and a late credit still ends with proof" do
    for timeout <- [1, 2, 10, 40] do
      peer = HelperPeer.bare()
      init = HelperPeer.open_frame(Child.argv(@pause), timeout: timeout)

      # One burst: open, cancel, then a credit after the cancel.
      HelperPeer.send_raw(
        peer,
        with_header(init) <> <<0, 1, ?Q, 0, 4, ?R, 1, 0x20, 0>>
      )

      terminal = terminal_after_started(peer)

      assert <<?E, reason, _::32>> = terminal
      assert reason in [1, 2]
      HelperPeer.finish(peer)
    end
  end

  test "a reader that closes its end retires the child and ends the helper with status 0", c do
    status = Path.join(c.directory, "closed-reader-status")
    helper_vm = Child.argv([{:helper_status, Native.executable(), status}])
    reader = start_vm([{:read_first_frame, helper_vm}, :hold], [{:line, 1024}])
    {:os_pid, reader_pid} = Port.info(reader, :os_pid)

    try do
      true = Port.command(reader, with_header(HelperPeer.open_frame(Child.argv(@pause))))

      # The reader takes the helper's first frame, which names the child, and
      # closes while stdin stays open. Closing it earlier would end the helper
      # before it starts a child.
      assert_receive {^reader, {:data, {:eol, "reader " <> names}}}, Child.deadline(750)
      names = names |> Base.decode16!() |> :erlang.binary_to_term()

      assert Processes.await_exit(names) == :ok
      assert File.read!(status) == "0\n"
    after
      kill(reader_pid)
    end
  end

  test "a reader that stops reading stalls the helper, which then fails its delivery", c do
    reader = start_vm([{:read_helper, c.small_pipe_helper}], [{:line, 256}])
    {:os_pid, reader_pid} = Port.info(reader, :os_pid)

    try do
      assert_receive {^reader, {:data, {:eol, "helper " <> helper_pid}}}, Child.deadline(750)
      helper = helper_pid |> String.to_integer() |> Processes.identity!()
      frame = HelperPeer.open_frame(Child.argv(@flood), timeout: Child.deadline(80))
      true = Port.command(reader, with_header(frame))
      assert_receive {^reader, {:data, {:eol, "started"}}}, Child.deadline(750)

      # The reader stops before the helper has output, so nothing drains the
      # helper's stdout pipe. One credit is all the helper will ever send.
      {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(reader_pid)])
      assert Processes.await_stopped(reader_pid) == :ok
      true = Port.command(reader, credit())

      assert Processes.await_exit([helper], Child.deadline(2000)) == :ok
      {_, 0} = System.cmd("kill", ["-CONT", Integer.to_string(reader_pid)])
      assert_receive {^reader, {:data, {:eol, "status 124"}}}, Child.deadline(750)
    after
      kill(reader_pid)
    end
  end

  # A second VM runs the steps. Only the VM that starts the helper holds the
  # other end of its pipes, so a test closes or suspends a reader through it.
  defp start_vm(steps, options) do
    [executable | arguments] = Child.argv(steps)

    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, {:args, arguments}] ++ options
    )
  end

  defp kill(pid),
    do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

  defp credit, do: <<0, 4, ?R, 1, 0x20, 0>>

  defp with_header(frame), do: <<byte_size(frame)::16, frame::binary>>

  defp detached do
    peer = HelperPeer.start(Child.argv(@detached), timeout: 0)
    HelperPeer.grant(peer, 1)
    <<?D, 1, text::binary>> = HelperPeer.receive_frame(peer)
    {peer, Processes.identity!(text |> String.trim() |> String.to_integer())}
  end

  defp wait_for_terminal(peer) do
    case HelperPeer.receive_frame(peer) do
      <<?E, _::binary>> = terminal -> terminal
      <<?Z, _stream>> -> wait_for_terminal(peer)
      <<?D, _::binary>> -> wait_for_terminal(peer)
    end
  end

  defp collect_until_terminal(peer, acknowledgements) do
    case HelperPeer.receive_frame(peer) do
      <<?E, _::binary>> = terminal ->
        {acknowledgements, terminal}

      <<?A, _::binary>> = ack ->
        collect_until_terminal(peer, [ack | acknowledgements])

      <<kind, _::binary>> when kind in [?D, ?Z, ?C] ->
        collect_until_terminal(peer, acknowledgements)
    end
  end

  defp terminal_after_started(peer) do
    case HelperPeer.receive_frame(peer) do
      <<?E, _::binary>> = terminal -> terminal
      <<?S, _::binary>> -> terminal_after_started(peer)
    end
  end
end
