defmodule LibTmux.NativeContractTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.{HelperPeer, Processes}
  alias LibTmux.Transport.Native

  @moduletag :integration
  @moduletag reason: "Qualifies the private helper protocol, credits and retirement under faults"

  @pause "exec sleep 1000"
  @ignore_term ~S(trap '' TERM; exec sleep 1000)

  # A shell child that outlives its parent: it detaches, ignores SIGTERM and
  # reports its pid on stdout. The shell itself keeps running as the direct child.
  @detached ~S(setsid -f sh -c 'trap "" TERM; echo $$; exec sleep 1000'; exec sleep 1000)

  defp sh(script), do: ["/bin/sh", "-c", script]

  setup_all do
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
    peer = HelperPeer.start(sh(~S(printf 'out\000\377'; printf err >&2; exit 7)))
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
    peer = HelperPeer.start(sh(~S(yes yyyyyyyy >&2 & exec yes xxxxxxxx)), stdin: true)
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
    peer = HelperPeer.start(sh(@ignore_term), timeout: 80)

    assert HelperPeer.receive_frame(peer) == <<?E, 2, 137::32>>
    HelperPeer.finish(peer)
  end

  test "a write after the child exited is refused with a failed acknowledgement" do
    script = ~S(dd bs=1 count=1 of=/dev/null 2>/dev/null; printf exit; exit 7)
    peer = HelperPeer.start(sh(script), timeout: 0, stdin: true)
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
    cwd_failure = HelperPeer.open_frame([System.find_executable("sh")], cwd: "/missing-cwd")
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
    peer = HelperPeer.start(sh(@pause))
    HelperPeer.grant(peer, 1)
    HelperPeer.grant(peer, 1)

    assert <<?F, 1, _::binary>> = HelperPeer.receive_frame(peer)
    HelperPeer.finish(peer)
  end

  test "a startup that races cancellation and a late credit still ends with proof" do
    for timeout <- [1, 2, 10, 40] do
      peer = HelperPeer.bare()
      init = HelperPeer.open_frame(sh(@pause), timeout: timeout)

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
    marker = "1000.#{System.unique_integer([:positive])}"
    status = Path.join(c.directory, "closed-reader-status")
    # The reader takes one byte, which is the start of the helper's first frame,
    # and exits. Closing it earlier would end the helper before it starts a child.
    script = ~S({ "$0"; echo $? >"$1"; } | head -c 1 >/dev/null)
    port = shell_port(script, [Native.executable(), status])
    send_open(port, sh("exec sleep " <> marker))

    assert_receive {^port, {:exit_status, 0}}, 750
    assert File.read!(status) == "0\n"
    assert processes_running(marker) == []
  end

  test "a reader that stops reading stalls the helper, which then fails its delivery", c do
    status = Path.join(c.directory, "stalled-reader-status")
    # The reader stops itself, so nothing drains the helper's stdout pipe.
    script =
      ~S({ "$0"; echo "status $?" >&2; } | { sh -c 'echo "reader $$" >&2; kill -STOP $$'; })

    port = shell_port(script, [c.small_pipe_helper, status])
    send_open(port, sh("exec yes xxxxxxxx"), timeout: 80)

    try do
      assert receive_stalled_report(port) == "124"
    after
      if reader = Process.get(:stalled_reader), do: System.cmd("kill", ["-KILL", reader])
    end
  end

  defp shell_port(script, arguments) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-c", script | arguments]}
    ])
  end

  defp send_open(port, argv, options \\ []) do
    frame = HelperPeer.open_frame(argv, options)
    true = Port.command(port, <<byte_size(frame)::16, frame::binary>>)
    # One credit is all the stalled reader will ever see.
    true = Port.command(port, <<0, 4, ?R, 1, 0x20, 0>>)
  end

  # The stopped reader never exits on its own, so remember it for the caller to kill.
  defp receive_stalled_report(port, seen \\ "") do
    receive do
      {^port, {:data, data}} ->
        seen = seen <> data
        reader = Regex.run(~r/reader (\d+)/, seen)
        if reader, do: Process.put(:stalled_reader, List.last(reader))

        case Regex.run(~r/status (\d+)/, seen) do
          [_, status] -> status
          nil -> receive_stalled_report(port, seen)
        end
    after
      2_000 -> flunk("the stalled helper did not report")
    end
  end

  defp processes_running(marker) do
    for command <- Path.wildcard("/proc/[0-9]*/cmdline"),
        {:ok, text} <- [File.read(command)],
        String.contains?(text, marker),
        do: command
  end

  defp with_header(frame), do: <<byte_size(frame)::16, frame::binary>>

  defp detached do
    peer = HelperPeer.start(sh(@detached), timeout: 0)
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
