defmodule LibTmux.ServerLifecycleIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Command, Error, Server}
  alias LibTmux.Test.{Processes, TmuxPath}

  @moduletag :integration
  @moduletag reason: "Starts and stops real tmux servers in private directories"

  setup do
    tmux = TmuxPath.executable()

    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-life-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, tmux: tmux, root: root}
  end

  defp output!(server, name, args) do
    {:ok, %{stdout: stdout}} = Server.run(server, Command.new(name, args))
    stdout
  end

  defp pids(server) do
    server_pid = server |> output!("display-message", ["-p", ~S"#{pid}"]) |> String.trim()

    pane_pids =
      server |> output!("list-panes", ["-a", "-F", ~S"#{pane_pid}"]) |> String.split()

    Enum.map([server_pid | pane_pids], &Processes.identity!(String.to_integer(&1)))
  end

  test "start returns a private server that answers, and stop removes everything", c do
    assert {:ok, %Server{} = server} = Server.start(executable: c.tmux, root: c.root)
    assert [directory] = File.ls!(c.root)
    directory = Path.join(c.root, directory)
    assert server.socket == Path.join(directory, "tmux.sock")
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700

    assert {:ok, %{value: %{id: "$0"}}} =
             Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

    processes = pids(server)
    assert length(processes) == 2

    assert :ok = Server.stop(server)
    assert Processes.await_exit(processes) == :ok
    assert File.ls!(c.root) == []
    assert :ok = Server.stop(server)
  end

  test "the daemon gets a private TMUX_TMPDIR, the overlay and no tmux context", c do
    env = %{"TMUX" => "/nowhere,1,0", "TMUX_PANE" => "%9", "LIBTMUX_LIFECYCLE" => "marked"}
    assert {:ok, server} = Server.start(executable: c.tmux, root: c.root, env: env)

    try do
      global = output!(server, "show-environment", ["-g"])
      directory = Path.dirname(server.socket)
      assert global =~ "TMUX_TMPDIR=#{directory}\n"
      assert global =~ "LIBTMUX_LIFECYCLE=marked\n"
      refute global =~ ~r/^TMUX=/m
      refute global =~ ~r/^TMUX_PANE=/m
    after
      assert :ok = Server.stop(server)
    end
  end

  test "start uses the given configuration file", c do
    config = Path.join(c.root, "tmux.conf")
    File.write!(config, "set -g @libtmux_config loaded\n")
    assert {:ok, server} = Server.start(executable: c.tmux, root: c.root, config_file: config)

    try do
      assert output!(server, "show-options", ["-gv", "@libtmux_config"]) == "loaded\n"
    after
      assert :ok = Server.stop(server)
    end
  end

  test "a tmux that cannot serve returns an error and leaves no directory", c do
    assert {:error, %Error{kind: :server_start_failed, phase: :start}} =
             Server.start(executable: "/bin/false", root: c.root)

    assert File.ls!(c.root) == []
  end

  test "an executable that does not exist returns an error and leaves no directory", c do
    assert {:error, %Error{kind: kind}} =
             Server.start(executable: Path.join(c.root, "missing"), root: c.root)

    assert kind in [:launch_failed, :server_start_failed]
    assert File.ls!(c.root) == []
  end

  test "two servers do not share a directory or a session namespace", c do
    {:ok, first} = Server.start(executable: c.tmux, root: c.root)
    {:ok, second} = Server.start(executable: c.tmux, root: c.root)

    try do
      refute first.socket == second.socket
      {:ok, _} = Server.new_session(first, "only-first", command: {:argv, ["/bin/cat"]})
      assert output!(first, "list-sessions", ["-F", ~S"#{session_name}"]) == "only-first\n"
      assert output!(second, "list-sessions", []) == ""
    after
      assert :ok = Server.stop(first)
      assert :ok = Server.stop(second)
    end
  end

  test "with_owned returns the function's value and stops the server", c do
    result =
      Server.with_owned([executable: c.tmux, root: c.root], fn server ->
        {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
        {server, pids(server)}
      end)

    assert {%Server{}, processes} = result
    assert Processes.await_exit(processes) == :ok
    assert File.ls!(c.root) == []
  end

  test "with_owned stops the server when the function raises", c do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    assert_raise RuntimeError, "boom", fn ->
      Server.with_owned([executable: c.tmux, root: c.root], fn server ->
        Agent.update(agent, fn _ -> server end)
        raise "boom"
      end)
    end

    server = Agent.get(agent, & &1)
    assert File.ls!(c.root) == []
    assert {:error, _} = Server.run(server, Command.new("list-sessions", []))
  end

  test "a failing stop never replaces the function's exception", c do
    assert_raise RuntimeError, "boom", fn ->
      Server.with_owned([executable: c.tmux, root: c.root], fn server ->
        # A directory without write permission cannot lose its socket file.
        File.chmod!(Path.dirname(server.socket), 0o500)
        raise "boom"
      end)
    end

    assert [directory] = File.ls!(c.root)
    File.chmod!(Path.join(c.root, directory), 0o700)
  end

  test "stop keeps the directory and reports when it cannot remove it", c do
    {:ok, server} = Server.start(executable: c.tmux, root: c.root)
    directory = Path.dirname(server.socket)
    File.chmod!(directory, 0o500)

    assert {:error, %Error{kind: :cleanup_failed}} = Server.stop(server)
    assert File.dir?(directory)

    File.chmod!(directory, 0o700)
    assert :ok = Server.stop(server)
    assert File.ls!(c.root) == []
  end

  test "a server that the function killed still stops cleanly", c do
    assert {:ok, _} =
             Server.with_owned([executable: c.tmux, root: c.root], fn server ->
               {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
               Server.run(server, Command.new("kill-server", []))
             end)

    assert File.ls!(c.root) == []
  end

  test "the server stops when its owner exits", c do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, server} = Server.start(executable: c.tmux, root: c.root)
        {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
        send(parent, {:started, pids(server)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:started, processes}, 5_000
    assert Enum.all?(processes, &Processes.alive?/1)
    Process.exit(owner, :kill)
    assert Processes.await_exit(processes) == :ok
    assert wait_for_empty(c.root)
  end

  defp wait_for_empty(root, attempts \\ 200) do
    cond do
      File.ls!(root) == [] ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          5 -> wait_for_empty(root, attempts - 1)
        end
    end
  end
end
