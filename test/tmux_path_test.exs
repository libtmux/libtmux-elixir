Code.ensure_loaded?(LibTmux.ExampleCheck) ||
  Code.require_file("../scripts/check_examples.exs", __DIR__)

defmodule LibTmux.TmuxPathTest do
  use ExUnit.Case, async: true

  alias LibTmux.ExampleCheck
  alias LibTmux.Test.TmuxPath

  describe "executable selection" do
    test "prefers LIBTMUX_TEST_TMUX over LIBTMUX_TMUX and PATH" do
      env = %{
        "LIBTMUX_TEST_TMUX" => "/opt/test/tmux",
        "LIBTMUX_TMUX" => "/opt/legacy/tmux"
      }

      path_lookup = fn "tmux" -> "/usr/bin/tmux" end

      assert TmuxPath.executable(env, path_lookup) == "/opt/test/tmux"
      assert ExampleCheck.executable(env, path_lookup) == "/opt/test/tmux"
    end

    test "treats missing, empty and whitespace-only LIBTMUX_TEST_TMUX as unset" do
      path_lookup = fn "tmux" -> "/usr/bin/tmux" end

      for blank <- [nil, "", " ", "\t\n  "] do
        env =
          case blank do
            nil -> %{"LIBTMUX_TMUX" => "/opt/legacy/tmux"}
            value -> %{"LIBTMUX_TEST_TMUX" => value, "LIBTMUX_TMUX" => "/opt/legacy/tmux"}
          end

        assert TmuxPath.executable(env, path_lookup) == "/opt/legacy/tmux"
        assert ExampleCheck.executable(env, path_lookup) == "/opt/legacy/tmux"
      end
    end

    test "falls back to PATH when both variables are unset or blank, and raises when absent" do
      env = %{"LIBTMUX_TEST_TMUX" => "  ", "LIBTMUX_TMUX" => "\t"}

      assert TmuxPath.executable(env, fn "tmux" -> "/usr/bin/tmux" end) == "/usr/bin/tmux"
      assert ExampleCheck.executable(env, fn "tmux" -> "/usr/bin/tmux" end) == "/usr/bin/tmux"

      assert_raise RuntimeError, ~r/require an explicit tmux binary or tmux on PATH/, fn ->
        TmuxPath.executable(env, fn "tmux" -> nil end)
      end

      assert_raise RuntimeError, ~r/packed examples require tmux/, fn ->
        ExampleCheck.executable(env, fn "tmux" -> nil end)
      end
    end
  end

  describe "ambient selector scrubbing" do
    test "TmuxPath.clean_env and TmuxPath.environment scrub TMUX, TMUX_PANE and LIBTMUX_SOCKET*" do
      sandbox = System.fetch_env!("TMUX_TMPDIR")
      root = TmuxPath.private_directory(sandbox, "tmux-path")
      on_exit(fn -> File.rm_rf(root) end)

      bin = Path.join(root, "bin")
      tmp = Path.join(root, "tmp")
      File.mkdir!(tmp)

      ambient = %{
        "TMUX" => "/tmp/ambient.sock,123,0",
        "TMUX_PANE" => "%4",
        "LIBTMUX_SOCKET" => "work",
        "LIBTMUX_SOCKET_PATH" => "/tmp/work.sock",
        "LIBTMUX_SOCKET_NAME" => "legacy",
        "LIBTMUX_TEST_TMUX" => "/opt/test/tmux",
        "LIBTMUX_TMUX" => "/opt/legacy/tmux",
        "PATH" => "/usr/bin:/bin",
        "HOME" => "/home/tester"
      }

      cleaned = TmuxPath.clean_env(ambient)

      for removed <- [
            "TMUX",
            "TMUX_PANE",
            "LIBTMUX_SOCKET",
            "LIBTMUX_SOCKET_PATH",
            "LIBTMUX_SOCKET_NAME"
          ] do
        refute Map.has_key?(cleaned, removed)
      end

      assert cleaned["LIBTMUX_TEST_TMUX"] == "/opt/test/tmux"
      assert cleaned["LIBTMUX_TMUX"] == "/opt/legacy/tmux"
      assert cleaned["HOME"] == "/home/tester"

      prepared = TmuxPath.environment("/bin/echo", bin, tmp, ambient)

      for removed <- [
            "TMUX",
            "TMUX_PANE",
            "LIBTMUX_SOCKET",
            "LIBTMUX_SOCKET_PATH",
            "LIBTMUX_SOCKET_NAME"
          ] do
        refute Map.has_key?(prepared, removed)
      end

      assert prepared["PATH"] == bin <> ":/usr/bin:/bin"
      assert prepared["TMPDIR"] == tmp
      assert File.read_link!(Path.join(bin, "tmux")) == "/bin/echo"
    end

    test "ExampleCheck.pure_env and sandbox_env scrub ambient selectors for OneShot and System.cmd" do
      ambient = %{
        "TMUX" => "/tmp/ambient.sock,123,0",
        "TMUX_PANE" => "%4",
        "LIBTMUX_SOCKET" => "work",
        "LIBTMUX_SOCKET_PATH" => "/tmp/work.sock",
        "LIBTMUX_SOCKET_NAME" => "legacy",
        "LIBTMUX_TEST_TMUX" => "/opt/test/tmux",
        "ERL_LIBS" => "/leak/libs",
        "PATH" => "/usr/bin:/bin"
      }

      pure = ExampleCheck.pure_env(ambient)

      for removed <- [
            "TMUX",
            "TMUX_PANE",
            "LIBTMUX_SOCKET",
            "LIBTMUX_SOCKET_PATH",
            "LIBTMUX_SOCKET_NAME",
            "ERL_LIBS"
          ] do
        refute Map.has_key?(pure, removed)
      end

      assert pure["LIBTMUX_TEST_TMUX"] == "/opt/test/tmux"

      sandbox_entries = Map.new(ExampleCheck.sandbox_env("/tmp/example-root", ambient))

      for cleared <- [
            "TMUX",
            "TMUX_PANE",
            "LIBTMUX_SOCKET",
            "LIBTMUX_SOCKET_PATH",
            "LIBTMUX_SOCKET_NAME",
            "ERL_LIBS"
          ] do
        assert Map.fetch!(sandbox_entries, cleared) == nil
      end

      assert sandbox_entries["PATH"] == "/tmp/example-root/bin:/usr/bin:/bin"
      assert sandbox_entries["TMPDIR"] == "/tmp/example-root/tmp"
    end
  end
end
