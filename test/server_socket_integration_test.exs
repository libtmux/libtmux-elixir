defmodule LibTmux.ServerSocketIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Control, Server, Snapshot}
  alias LibTmux.Control.Request

  @moduletag :integration
  @moduletag reason:
               "Qualifies the socket a Server reaches against tmux servers in a private TMUX_TMPDIR"

  # Every server below lives under this test's own TMUX_TMPDIR, so a socket
  # that is wrongly chosen or wrongly omitted still cannot reach a server
  # outside it. The decoy servers prove that the right one answered.
  setup do
    tmux = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    dir = Path.join(System.tmp_dir!(), "ltx-sock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, tmux: tmux, dir: dir, path: Path.join(dir, "chosen.sock")}
  end

  test "no socket reaches the default socket of TMUX_TMPDIR", context do
    start(context, [], "default-session")
    start(context, ["-L", "decoy"], "decoy-session")

    assert sessions(context, %{}) == ["default-session"]
  end

  test "no socket follows the server TMUX names", context do
    start(context, [], "default-session")
    start(context, ["-S", context.path], "followed-session")

    assert sessions(context, inside(context)) == ["followed-session"]
  end

  test "a socket from a variable wins over TMUX", context do
    start(context, ["-S", context.path], "followed-session")
    start(context, ["-L", "work"], "named-session")

    variables = Map.put(inside(context), "LIBTMUX_SOCKET", "work")

    assert sessions(context, variables) == ["named-session"]
  end

  test "LIBTMUX_SOCKET reaches the named socket", context do
    start(context, [], "default-session")
    start(context, ["-L", "work"], "named-session")

    assert sessions(context, %{"LIBTMUX_SOCKET" => "work"}) == ["named-session"]
  end

  test "LIBTMUX_SOCKET_PATH reaches the socket at that path", context do
    start(context, [], "default-session")
    start(context, ["-S", context.path], "path-session")

    assert sessions(context, %{"LIBTMUX_SOCKET_PATH" => context.path}) == ["path-session"]
  end

  test "the path wins when both variables are set", context do
    start(context, ["-L", "decoy"], "named-session")
    start(context, ["-S", context.path], "path-session")

    variables = %{"LIBTMUX_SOCKET_PATH" => context.path, "LIBTMUX_SOCKET" => "decoy"}

    assert sessions(context, variables) == ["path-session"]
  end

  test "an explicit socket or socket name wins over both variables", context do
    start(context, ["-L", "work"], "named-session")
    start(context, ["-S", context.path], "path-session")
    start(context, ["-L", "decoy"], "decoy-session")

    decoys = %{
      "LIBTMUX_SOCKET_PATH" => Path.join(context.dir, "absent.sock"),
      "LIBTMUX_SOCKET" => "decoy"
    }

    assert sessions(context, decoys, socket: context.path) == ["path-session"]
    assert sessions(context, decoys, socket_name: "work") == ["named-session"]
  end

  test "managed control attaches to the server the chosen socket reaches", context do
    start(context, [], "default-session")
    start(context, ["-L", "work"], "named-session")
    start(context, ["-S", context.path], "followed-session")

    for {variables, flags} <- [
          {%{}, []},
          {%{"LIBTMUX_SOCKET" => "work"}, ["-L", "work"]},
          {inside(context), ["-S", context.path]}
        ] do
      pid = String.trim(tmux(context, flags ++ ["display-message", "-p", ~S"#{pid}"]))

      options = [
        server: server(context, variables),
        session: {:existing, "$0"},
        lane: :host_qualified,
        timeout: 1500
      ]

      assert {:ok, {:ok, %{outcome: :completed, lines: ["v1:" <> ^pid]}}} =
               Control.with_connection(options, fn control ->
                 Control.execute(control, Request.field("pid"), timeout: 1500)
               end)
    end
  end

  defp sessions(context, variables, options \\ []) do
    context
    |> server(variables, options)
    |> Server.snapshot!()
    |> Snapshot.sessions()
    |> Enum.map(& &1.name)
  end

  defp server(context, variables, options \\ []) do
    env = Map.put(variables, "TMUX_TMPDIR", context.dir)

    # No test runs with the TMUX of the shell it was started from. A TMUX it
    # passes names a socket inside its own directory.
    if tmux = env["TMUX"], do: assert(String.starts_with?(tmux, context.dir <> "/"))

    Server.new([executable: context.tmux, env: env] ++ options)
  end

  defp inside(context),
    do: %{"TMUX" => context.path <> ",4242,0", "TMUX_PANE" => "%0"}

  defp start(context, flags, session) do
    assert {_, 0} =
             System.cmd(
               context.tmux,
               ["-f", "/dev/null"] ++ flags ++ ["new-session", "-d", "-s", session, "/bin/cat"],
               env: environment(context),
               stderr_to_stdout: true
             )

    on_exit(fn -> stop(context, flags) end)
  end

  defp stop(context, flags) do
    System.cmd(context.tmux, flags ++ ["kill-server"],
      env: environment(context),
      stderr_to_stdout: true
    )

    assert eventually(fn ->
             {_, status} =
               System.cmd(context.tmux, flags ++ ["list-sessions"],
                 env: environment(context),
                 stderr_to_stdout: true
               )

             status != 0
           end),
           "a test server is still answering"
  end

  defp tmux(context, arguments) do
    assert {output, 0} =
             System.cmd(context.tmux, arguments,
               env: environment(context),
               stderr_to_stdout: true
             )

    output
  end

  defp environment(context),
    do: [{"TMUX_TMPDIR", context.dir}, {"TMUX", nil}, {"TMUX_PANE", nil}]

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
