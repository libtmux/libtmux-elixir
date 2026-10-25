[example, executable, socket, session] = System.argv()
System.argv([executable, socket, session])
Code.require_file(example)

unless Code.ensure_loaded?(LibTmux.Test.OwnedTmux),
  do: Code.require_file("owned_tmux.ex", __DIR__)

defmodule LibTmux.Test.SupervisionCases do
  import ExUnit.Assertions
  alias LibTmux.{Command, Control, Error, Server}
  alias LibTmux.Control.Request
  alias LibTmux.Test.OwnedTmux

  def run(executable, socket, session) do
    Logger.configure(level: :critical)
    server = Server.new(executable: executable, socket: socket)
    {:ok, application} = Supervisor.start_link([], strategy: :one_for_one)
    monitor = Process.monitor(application)

    try do
      {:ok, connections} =
        Supervisor.start_child(application, %{
          id: :connections,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
          type: :supervisor
        })

      options = [
        server: server,
        session: {:existing, session},
        lane: :host_qualified,
        timeout: 900
      ]

      {:ok, owner} =
        Supervisor.start_child(application, {ApplicationConnection, {connections, options}})

      {:ok, original} = ApplicationConnection.connection(owner)

      assert {:ok, %{outcome: :completed}} =
               ApplicationConnection.execute(
                 owner,
                 Request.set_user_option("@supervision_case", "once")
               )

      assert "once\n" == command(server, ["show-options", "-sv", "@supervision_case"])
      command(server, ["set-option", "-s", "@supervision_case", "changed-after-completion"])

      native = native_watch(original)
      assert :ok = Control.close(original, timeout: 900)
      assert :ok = OwnedTmux.await_exit(native)
      restart_root(connections)
      assert {:error, %Error{kind: :connection_lost}} = Control.status(original)

      assert {:error, %Error{kind: :connection_lost}} =
               ApplicationConnection.execute(owner, Request.field("pid"))

      assert "" == command(server, ["list-clients", "-F", ~S"#{client_pid}"])
      {:ok, inert} = ApplicationConnection.replace(owner)
      assert {:ok, %{phase: :retired}} = Control.status(inert)

      assert {:error, %Error{kind: :not_ready}} =
               ApplicationConnection.execute(owner, Request.field("pid"))

      {:ok, ready} = ApplicationConnection.reconnect(owner)

      assert {:ok, %{outcome: :completed}} =
               ApplicationConnection.execute(owner, Request.field("pid"))

      assert "changed-after-completion\n" ==
               command(server, ["show-options", "-sv", "@supervision_case"])

      native = native_watch(ready)
      restart_root(connections)
      assert :ok = OwnedTmux.await_exit(native)

      assert {:error, %Error{kind: :connection_lost}} =
               ApplicationConnection.execute(owner, Request.field("pid"))

      {:ok, unknown} = ApplicationConnection.replace(owner)
      assert {:ok, %{phase: :unknown}} = Control.status(unknown)
      assert {:error, %Error{kind: :cleanup_unknown}} = ApplicationConnection.reconnect(owner)

      assert {:error, %Error{kind: :not_ready}} =
               ApplicationConnection.execute(owner, Request.field("pid"))

      assert "" == command(server, ["list-clients", "-F", ~S"#{client_pid}"])

      assert "changed-after-completion\n" ==
               command(server, ["show-options", "-sv", "@supervision_case"])
    after
      :ok = Supervisor.stop(application, :normal, 950)
      assert_receive {:DOWN, ^monitor, :process, ^application, :normal}, 900
    end

    IO.puts(
      JSON.encode!(%{supervision_cases: "ok", native_exited: true, unknown_cleanup_refused: true})
    )
  end

  defp command(server, [name | arguments]) do
    {:ok, %{stdout: stdout}} = Server.run(server, Command.new(name, arguments))
    stdout
  end

  defp native_watch(control) do
    guardian = :sys.get_state(control.endpoint.manager).actors.guardian
    state = :sys.get_state(guardian)
    {:os_pid, helper} = Port.info(state.handle, :os_pid)
    OwnedTmux.watch_processes([state.child, helper])
  end

  defp restart_root(supervisor) do
    [{Control, root, :supervisor, _}] = Supervisor.which_children(supervisor)
    observer = self()
    token = make_ref()

    tracer =
      spawn(fn ->
        receive do
          {:trace, ^supervisor, :spawn, replacement, _} ->
            send(observer, {token, replacement})
        after
          900 -> send(observer, {token, :missing})
        end
      end)

    monitor = Process.monitor(root)
    :erlang.trace(supervisor, true, [:procs, {:tracer, tracer}])

    try do
      Process.exit(root, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, 900
      assert_receive {^token, replacement}, 900
      assert is_pid(replacement) and replacement != root
      assert [{Control, ^replacement, :supervisor, _}] = Supervisor.which_children(supervisor)
    after
      :erlang.trace(supervisor, false, [:procs])
      Process.exit(tracer, :kill)
    end
  end
end

LibTmux.Test.SupervisionCases.run(executable, socket, session)
