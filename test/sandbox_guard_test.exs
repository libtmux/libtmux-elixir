defmodule LibTmux.SandboxGuardTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.SandboxGuard

  test "the suite runs with no inherited tmux context and a private TMUX_TMPDIR" do
    dir = System.fetch_env!("TMUX_TMPDIR")

    assert SandboxGuard.verify(System.get_env(), dir) == []
  end

  test "inherited names the tmux variables and the socket variables, nothing else" do
    env = %{
      "TMUX" => "x",
      "TMUX_PANE" => "%0",
      "TMUX_TMPDIR" => "/x",
      "LIBTMUX_SOCKET" => "x",
      "LIBTMUX_SOCKET_PATH" => "/x",
      "LIBTMUX_TMUX" => "/usr/bin/tmux",
      "PATH" => "/bin"
    }

    assert SandboxGuard.inherited(env) ==
             ["LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH", "TMUX", "TMUX_PANE"]
  end

  describe "verify/2 refuses" do
    test "an environment that still carries tmux context, naming it and not its value" do
      dir = System.fetch_env!("TMUX_TMPDIR")

      env = %{
        "TMUX_TMPDIR" => dir,
        "TMUX" => "leak-one",
        "LIBTMUX_SOCKET" => "leak-two",
        "LIBTMUX_SOCKET_PATH" => "/leak-three"
      }

      problems = SandboxGuard.verify(env, dir)

      assert problems == [
               "LIBTMUX_SOCKET is set",
               "LIBTMUX_SOCKET_PATH is set",
               "TMUX is set"
             ]
    end

    test "a TMUX_TMPDIR that is not the sandbox directory, without repeating it" do
      dir = System.fetch_env!("TMUX_TMPDIR")

      assert SandboxGuard.verify(%{"TMUX_TMPDIR" => "/leak-four"}, dir) ==
               ["TMUX_TMPDIR is not the sandbox directory"]

      assert SandboxGuard.verify(%{}, dir) == ["TMUX_TMPDIR is not the sandbox directory"]
    end
  end

  describe "problems/1" do
    test "accepts the sandbox directory" do
      assert SandboxGuard.problems(System.fetch_env!("TMUX_TMPDIR")) == []
    end

    test "refuses a path that is relative, long, missing or not a directory" do
      sandbox = System.fetch_env!("TMUX_TMPDIR")
      file = Path.join(sandbox, "guard-file-#{System.unique_integer([:positive])}")
      File.write!(file, "")
      on_exit(fn -> File.rm(file) end)

      assert SandboxGuard.problems("relative/leak") == ["TMUX_TMPDIR is not an absolute path"]
      assert SandboxGuard.problems(nil) == ["TMUX_TMPDIR is not an absolute path"]

      assert SandboxGuard.problems(Path.join(sandbox, String.duplicate("l", 100))) ==
               ["a socket under TMUX_TMPDIR would exceed 100 bytes"]

      assert SandboxGuard.problems(Path.join(sandbox, "absent")) == ["TMUX_TMPDIR does not exist"]
      assert SandboxGuard.problems(file) == ["TMUX_TMPDIR is not a directory"]
    end

    test "refuses a directory others can read, write or search" do
      sandbox = System.fetch_env!("TMUX_TMPDIR")

      for mode <- [0o750, 0o705, 0o777, 0o770] do
        dir = Path.join(sandbox, "guard-#{mode}-#{System.unique_integer([:positive])}")
        File.mkdir!(dir)
        on_exit(fn -> File.rm_rf(dir) end)
        File.chmod!(dir, mode)

        assert SandboxGuard.problems(dir) == ["TMUX_TMPDIR is not owner-only"]
      end
    end
  end

  describe "sockets/1 and live/1" do
    test "tell a socket that answers from a stale file, and an empty directory from both" do
      sandbox = System.fetch_env!("TMUX_TMPDIR")
      dir = Path.join(sandbox, "guard-scan-#{System.unique_integer([:positive])}")
      File.mkdir!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert SandboxGuard.sockets(dir) == []
      assert SandboxGuard.live(dir) == []

      path = Path.join(dir, "left.sock")
      {:ok, listener} = :gen_tcp.listen(0, [:local, {:ip, {:local, String.to_charlist(path)}}])
      assert SandboxGuard.sockets(dir) == [path]
      assert SandboxGuard.live(dir) == ["left.sock"]

      :ok = :gen_tcp.close(listener)
      assert SandboxGuard.sockets(dir) == [path]
      assert SandboxGuard.live(dir) == []
    end
  end

  describe "a bare tmux" do
    @describetag :integration
    @describetag reason: "Starts a tmux server with no socket argument, in the sandbox only"

    test "lands in the sandbox, and moves with TMUX_TMPDIR" do
      tmux = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
      sandbox = System.fetch_env!("TMUX_TMPDIR")
      assert SandboxGuard.verify(System.get_env(), sandbox) == []

      elsewhere = Path.join(sandbox, "elsewhere")
      File.mkdir!(elsewhere)
      File.chmod!(elsewhere, 0o700)
      on_exit(fn -> File.rm_rf(elsewhere) end)

      bare = fn directory, arguments ->
        System.cmd(tmux, ["-f", "/dev/null"] ++ arguments,
          env: [{"TMUX_TMPDIR", directory}, {"TMUX", nil}, {"TMUX_PANE", nil}],
          stderr_to_stdout: true
        )
      end

      socket_in = fn directory -> Path.wildcard(Path.join(directory, "tmux-*/default")) end

      try do
        assert {_, 0} = bare.(sandbox, ["new-session", "-d", "-s", "canary", "/bin/cat"])
        assert [socket] = socket_in.(sandbox)
        assert SandboxGuard.answering?(socket)
        assert socket_in.(elsewhere) == []
      after
        bare.(sandbox, ["kill-server"])
      end

      try do
        assert {_, 0} = bare.(elsewhere, ["new-session", "-d", "-s", "control", "/bin/cat"])
        assert [socket] = socket_in.(elsewhere)
        assert SandboxGuard.answering?(socket)

        assert eventually(fn ->
                 not Enum.any?(socket_in.(sandbox), &SandboxGuard.answering?/1)
               end)
      after
        bare.(elsewhere, ["kill-server"])
      end
    end
  end

  defp eventually(check, attempts \\ 40) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(check, attempts - 1)
    end
  end
end
