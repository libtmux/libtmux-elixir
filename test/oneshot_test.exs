defmodule LibTmux.OneShotTest do
  use ExUnit.Case, async: true

  alias LibTmux.Transport.OneShot

  @moduletag :integration
  @moduletag reason: "Qualifies owned external process I/O, limits and retirement on Linux"

  test "stdout, stderr and process exit remain separate byte evidence" do
    assert {:ok, result} =
             OneShot.run(
               "/usr/bin/python3",
               [
                 "-c",
                 "import os;os.write(1,b'out\\x00\\xff');os.write(2,b'err');raise SystemExit(7)"
               ],
               max_stdout_bytes: 5,
               max_stderr_bytes: 3,
               max_chunks: 2
             )

    assert result.stdout == <<"out", 0, 255>>
    assert result.stderr == "err"
    assert result.exit_status == 7
    assert result.cleanup == :retired
  end

  test "output overload retains a bounded prefix and retires the producer" do
    assert {:error, error} =
             OneShot.run(
               "/usr/bin/python3",
               ["-c", "import os\nwhile True:os.write(1,b'x'*8192)"],
               max_stdout_bytes: 64
             )

    assert error.kind == :resource_limit
    assert error.certainty == :unknown
    assert error.details.reason == :stdout_bytes
    assert byte_size(error.details.stdout) == 64
    assert error.details.cleanup == :retired
  end

  test "a combined byte budget bounds stdout and stderr together" do
    assert {:error, error} =
             OneShot.run(
               "/usr/bin/python3",
               ["-c", "import os;os.write(1,b'out');os.write(2,b'err')"],
               max_total_bytes: 5
             )

    assert error.kind == :resource_limit
    assert error.details.reason == :total_bytes
    assert byte_size(error.details.stdout) + byte_size(error.details.stderr) == 5
    assert error.details.cleanup == :retired
  end

  test "one deadline returns partial bytes without treating them as success" do
    assert {:error, error} =
             OneShot.run(
               "/usr/bin/python3",
               [
                 "-c",
                 "import os,signal;os.write(1,b'ready');signal.pause()"
               ],
               timeout: 150
             )

    assert error.kind == :timeout
    assert error.certainty == :unknown
    assert error.details.stdout == "ready"
    assert error.details.cleanup == :retired
  end

  test "failed exec proves that the selected program did not start" do
    assert {:error, error} = OneShot.run("/missing-libtmux-executable", [])
    assert error.kind == :launch_failed
    assert error.phase == :spawn
    assert error.certainty == :no_write
    assert error.details.cleanup == :retired
  end

  test "an explicit tmux metadata client leaves its borrowed server alive" do
    fixture = start_supervised!({LibTmux.Test.OwnedTmux, []})
    info = LibTmux.Test.OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")

    assert {:ok, result} =
             OneShot.run(executable, [
               "-N",
               "-u",
               "-S",
               info.socket,
               "display-message",
               "-p",
               LibTmux.Format.field("pid")
             ])

    assert {:ok, info.server_pid} ==
             LibTmux.Codec.decode_field(result.stdout, :integer, encoding: :escaped_v1)

    assert {pid, 0} =
             LibTmux.Test.OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{pid}"])

    assert String.trim(pid) == Integer.to_string(info.server_pid)
  end

  test "target environments preserve empty, Unicode and raw byte values" do
    assert {:ok, result} =
             OneShot.run(
               "/usr/bin/python3",
               [
                 "-c",
                 ~S"import os;os.write(1,os.environb[b'EMPTY']+b'\0'+os.environb[b'UNICODE']+b'\0'+os.environb[b'RAW'])"
               ],
               env: %{
                 "EMPTY" => "",
                 "UNICODE" => "é日本語",
                 "RAW" => <<255>>,
                 "LD_PRELOAD" => "/missing-libtmux-target-library.so"
               }
             )

    assert result.exit_status == 0
    assert result.stdout == <<0, "é日本語", 0, 255>>
    assert String.contains?(result.stderr, "LD_PRELOAD")
  end

  test "an expired admission retains no-write certainty" do
    deadline = LibTmux.Deadline.new(1, now: System.monotonic_time(:millisecond) - 1000)

    assert {:error, %{kind: :timeout, certainty: :no_write, phase: :admission}} =
             OneShot.run("/bin/true", [], deadline: deadline)
  end
end
