defmodule LibTmux.ServerSocketTest do
  # Two tests set variables in the process environment, so this module runs
  # after the asynchronous ones and restores what it changes.
  use ExUnit.Case, async: false

  alias LibTmux.{Command, Server}
  alias LibTmux.Control.Bootstrap

  @path "/run/libtmux-test/server.sock"
  # A fake tmux context that points nowhere real. No test inherits the TMUX of
  # the shell it runs in.
  @inside_tmux %{"TMUX" => "/run/libtmux-test/followed.sock,4242,0", "TMUX_PANE" => "%0"}

  setup context do
    if context[:recorder] do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ltx-socket-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      recorder = Path.join(dir, "recorder")

      # Argv goes to stdout. Stderr names which tmux variables arrived and
      # never their values.
      File.write!(recorder, """
      #!/bin/sh
      for argument in "$@"; do printf '%s\\n' "$argument"; done
      if [ -n "${TMUX+x}" ]; then printf 'TMUX=set\\n' >&2; else printf 'TMUX=unset\\n' >&2; fi
      if [ -n "${TMUX_PANE+x}" ]; then printf 'TMUX_PANE=set\\n' >&2; else printf 'TMUX_PANE=unset\\n' >&2; fi
      """)

      File.chmod!(recorder, 0o755)
      {:ok, recorder: recorder}
    else
      :ok
    end
  end

  describe "the arguments one-shot execution sends" do
    @describetag :recorder

    test "pass no socket when no option and no variable names one", %{recorder: recorder} do
      server = Server.new(executable: recorder, env: %{})

      assert %Server{socket: nil, socket_name: nil} = server
      assert sent(server) == ["-N", "-u", "list-sessions"]
    end

    test "pass -S for LIBTMUX_SOCKET_PATH", %{recorder: recorder} do
      server = Server.new(executable: recorder, env: %{"LIBTMUX_SOCKET_PATH" => @path})

      assert sent(server) == ["-N", "-u", "-S", @path, "list-sessions"]
    end

    test "pass -L for LIBTMUX_SOCKET", %{recorder: recorder} do
      server = Server.new(executable: recorder, env: %{"LIBTMUX_SOCKET" => "work"})

      assert sent(server) == ["-N", "-u", "-L", "work", "list-sessions"]
    end

    test "pass only the path when both variables are set", %{recorder: recorder} do
      env = %{"LIBTMUX_SOCKET_PATH" => @path, "LIBTMUX_SOCKET" => "work"}

      assert sent(Server.new(executable: recorder, env: env)) ==
               ["-N", "-u", "-S", @path, "list-sessions"]
    end

    test "treat an empty variable as unset, each one alone", %{recorder: recorder} do
      name_only = %{"LIBTMUX_SOCKET_PATH" => "", "LIBTMUX_SOCKET" => "work"}
      path_only = %{"LIBTMUX_SOCKET_PATH" => @path, "LIBTMUX_SOCKET" => ""}
      neither = %{"LIBTMUX_SOCKET_PATH" => "", "LIBTMUX_SOCKET" => ""}

      assert sent(Server.new(executable: recorder, env: name_only)) ==
               ["-N", "-u", "-L", "work", "list-sessions"]

      assert sent(Server.new(executable: recorder, env: path_only)) ==
               ["-N", "-u", "-S", @path, "list-sessions"]

      assert sent(Server.new(executable: recorder, env: neither)) ==
               ["-N", "-u", "list-sessions"]
    end

    test "let an explicit :socket ignore both variables", %{recorder: recorder} do
      env = %{"LIBTMUX_SOCKET_PATH" => "/other/path.sock", "LIBTMUX_SOCKET" => "other"}
      server = Server.new(executable: recorder, socket: @path, env: env)

      assert sent(server) == ["-N", "-u", "-S", @path, "list-sessions"]
    end

    test "let an explicit :socket_name ignore both variables", %{recorder: recorder} do
      env = %{"LIBTMUX_SOCKET_PATH" => "/other/path.sock", "LIBTMUX_SOCKET" => "other"}
      server = Server.new(executable: recorder, socket_name: "work", env: env)

      assert sent(server) == ["-N", "-u", "-L", "work", "list-sessions"]
    end

    test "never turn the TMUX socket into a socket argument", %{recorder: recorder} do
      assert sent(Server.new(executable: recorder, env: @inside_tmux)) ==
               ["-N", "-u", "list-sessions"]
    end
  end

  describe "the tmux variables one-shot execution passes" do
    @describetag :recorder

    test "keep TMUX and TMUX_PANE when no socket is chosen", %{recorder: recorder} do
      server = Server.new(executable: recorder, env: @inside_tmux)

      assert arrived(server) == ["TMUX=set", "TMUX_PANE=set"]
    end

    test "invent neither when the environment has neither", %{recorder: recorder} do
      assert arrived(Server.new(executable: recorder, env: %{})) ==
               ["TMUX=unset", "TMUX_PANE=unset"]
    end

    test "remove both when a socket path is chosen", %{recorder: recorder} do
      by_option = Server.new(executable: recorder, socket: @path, env: @inside_tmux)

      by_variable =
        Server.new(
          executable: recorder,
          env: Map.put(@inside_tmux, "LIBTMUX_SOCKET_PATH", @path)
        )

      for server <- [by_option, by_variable] do
        assert arrived(server) == ["TMUX=unset", "TMUX_PANE=unset"]
      end
    end

    test "ignore a caller's keep_tmux_context for a Server that chose a socket", %{
      recorder: recorder
    } do
      server = Server.new(executable: recorder, socket: @path, env: @inside_tmux)

      assert arrived(server, keep_tmux_context: true) == ["TMUX=unset", "TMUX_PANE=unset"]
      assert sent(server, keep_tmux_context: true) == ["-N", "-u", "-S", @path, "list-sessions"]
    end

    test "ignore a caller's keep_tmux_context for a Server that chose none", %{
      recorder: recorder
    } do
      server = Server.new(executable: recorder, env: @inside_tmux)

      assert arrived(server, keep_tmux_context: false) == ["TMUX=set", "TMUX_PANE=set"]
      assert sent(server, keep_tmux_context: false) == ["-N", "-u", "list-sessions"]
    end

    test "remove both when a socket name is chosen", %{recorder: recorder} do
      by_option = Server.new(executable: recorder, socket_name: "work", env: @inside_tmux)

      by_variable =
        Server.new(
          executable: recorder,
          env: Map.put(@inside_tmux, "LIBTMUX_SOCKET", "work")
        )

      for server <- [by_option, by_variable] do
        assert arrived(server) == ["TMUX=unset", "TMUX_PANE=unset"]
      end
    end
  end

  describe "the environment the variables come from" do
    setup do
      saved =
        for name <- ["LIBTMUX_SOCKET_PATH", "LIBTMUX_SOCKET"], do: {name, System.get_env(name)}

      on_exit(fn ->
        for {name, value} <- saved,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
      end)

      System.put_env("LIBTMUX_SOCKET_PATH", @path)
      System.put_env("LIBTMUX_SOCKET", "work")
    end

    test "default to the process environment" do
      assert %Server{socket: @path, socket_name: nil} = Server.new(executable: "/unused/tmux")
    end

    test "read the :env option instead when it is given" do
      assert %Server{socket: nil, socket_name: nil} =
               Server.new(executable: "/unused/tmux", env: %{})

      assert %Server{socket: nil, socket_name: "named"} =
               Server.new(executable: "/unused/tmux", env: %{"LIBTMUX_SOCKET" => "named"})
    end
  end

  describe "invalid input" do
    test "names the variable and never its value" do
      invalid = [
        {"LIBTMUX_SOCKET_PATH", "leak-one/relative.sock"},
        {"LIBTMUX_SOCKET_PATH", "/leak-two\0.sock"},
        {"LIBTMUX_SOCKET", "leak-three/work"},
        {"LIBTMUX_SOCKET", "leak-four\0work"},
        {"LIBTMUX_SOCKET", "."},
        {"LIBTMUX_SOCKET", ".."}
      ]

      for {name, value} <- invalid do
        error =
          assert_raise ArgumentError, fn ->
            Server.new(executable: "/unused/tmux", env: %{name => value})
          end

        assert error.message =~ name
        refute error.message =~ String.slice(value, 0, 8)
      end
    end

    test "does not validate a variable that is not in use" do
      shadowed = %{"LIBTMUX_SOCKET_PATH" => @path, "LIBTMUX_SOCKET" => "bad/name"}
      overridden = %{"LIBTMUX_SOCKET_PATH" => "relative", "LIBTMUX_SOCKET" => "bad/name"}

      assert %Server{socket: @path, socket_name: nil} =
               Server.new(executable: "/unused/tmux", env: shadowed)

      assert %Server{socket: @path, socket_name: nil} =
               Server.new(executable: "/unused/tmux", socket: @path, env: overridden)
    end

    test "rejects a socket and a socket name together" do
      assert_raise ArgumentError, ~r/at most one of :socket and :socket_name/, fn ->
        Server.new(executable: "/unused/tmux", socket: @path, socket_name: "work", env: %{})
      end
    end

    test "refuses a hand-built server whose socket is malformed" do
      server = Server.new(executable: "/unused/tmux", env: %{})
      command = Command.new("list-sessions", [])

      for malformed <- [
            %{server | socket: 5},
            %{server | socket: :path},
            %{server | socket_name: 5},
            %{server | socket: @path, socket_name: "work"}
          ] do
        assert_raise ArgumentError, fn -> Server.run(malformed, command) end
        assert_raise ArgumentError, fn -> Server.prepare_command(malformed, command) end
        assert_raise ArgumentError, fn -> Bootstrap.arguments(malformed, "$0") end
      end
    end

    test "rejects an invalid explicit socket or socket name" do
      for options <- [
            [socket: "relative.sock"],
            [socket: "/bad\0socket"],
            [socket: nil],
            [socket_name: ""],
            [socket_name: "a/b"],
            [socket_name: "a\0b"],
            [socket_name: "."],
            [socket_name: ".."],
            [socket_name: nil]
          ] do
        assert_raise ArgumentError, fn ->
          Server.new([executable: "/unused/tmux", env: %{}] ++ options)
        end
      end
    end
  end

  describe "control attachment" do
    test "uses the same socket arguments as one-shot execution" do
      by_path = Server.new(executable: "/unused/tmux", socket: @path, env: %{})
      by_name = Server.new(executable: "/unused/tmux", socket_name: "work", env: %{})
      neither = Server.new(executable: "/unused/tmux", env: %{})

      assert ["-N", "-u", "-C", "-S", @path, "attach-session" | _] =
               Bootstrap.arguments(by_path, "$0")

      assert ["-N", "-u", "-C", "-L", "work", "attach-session" | _] =
               Bootstrap.arguments(by_name, "$0")

      assert ["-N", "-u", "-C", "attach-session" | _] = Bootstrap.arguments(neither, "$0")
    end
  end

  defp sent(server, options \\ []), do: lines(server, :stdout, options)
  defp arrived(server, options \\ []), do: lines(server, :stderr, options)

  defp lines(server, stream, options) do
    {:ok, result} =
      Server.run(server, Command.new("list-sessions", []), [timeout: 2000] ++ options)

    result |> Map.fetch!(stream) |> String.split("\n", trim: true)
  end
end
