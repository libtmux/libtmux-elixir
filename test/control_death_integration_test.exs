defmodule LibTmux.ControlDeathIntegrationTest do
  use ExUnit.Case,
    async: false,
    parameterize: [
      %{victim: :router},
      %{victim: :guardian},
      %{victim: :manager},
      %{victim: :root}
    ]

  alias LibTmux.{Control, Operation, Server}
  alias LibTmux.Control.{Births, Lifetime, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag reason: "Qualifies real actor death, inert restart and native retirement"

  test "actor death fences the old handle and preserves the borrowed server", %{victim: victim} do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})

    parent =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor,
        restart: :temporary
      })

    factory =
      Control.child_spec(
        server: server,
        session: {:existing, "$0"},
        lane: :host_qualified,
        timeout: 800,
        capacity: 1,
        metadata_capacity: 4,
        waiter_capacity: 1
      )

    started = make_ref()

    factory = %{
      factory
      | start: {__MODULE__, :start_and_report, [factory.start, self(), started]}
    }

    assert {:ok, root, control} = Supervisor.start_child(parent, factory)
    assert_receive {^started, ^root}, 100
    endpoint = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    actors = Map.merge(roles, %{root: root, host: host, manager: endpoint.manager})
    monitors = Map.new(actors, fn {role, pid} -> {role, {pid, Process.monitor(pid)}} end)
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
    terminal = watch_terminal(endpoint.manager)
    assert :ok = :sys.suspend(roles.router, 500)

    assert {:ok, operation} =
             Control.submit(control, Request.set_user_option("@death_probe", "original"),
               timeout: 5000
             )

    native = OwnedTmux.watch_processes([helper, guardian.child])
    deadline = System.monotonic_time(:millisecond) + 950
    {pid, monitor} = monitors[victim]
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, remaining(deadline)
    refute Process.alive?(pid)

    if victim != :router do
      try do
        :sys.resume(roles.router, remaining(deadline))
      catch
        :exit, _ -> :ok
      end
    end

    expected =
      case victim do
        :root -> Map.keys(actors)
        :manager -> [:host, :manager, :epoch_supervisor, :router, :guardian]
        _ -> [:epoch_supervisor, :router, :guardian]
      end

    exited(for(role <- expected, role != victim, do: monitors[role]), deadline)
    assert :ok = OwnedTmux.await_exit(native)

    case victim do
      :root ->
        assert_receive {^started, replacement}, remaining(deadline)
        assert replacement != root
        inert(replacement, deadline)

      :manager ->
        inert(root, deadline)

      _ ->
        assert_receive {^terminal, phase}, remaining(deadline)
        assert phase == if(victim == :router, do: :closed, else: :unknown)
    end

    phase = Lifetime.status(control.lifetime)

    if victim == :guardian,
      do: assert({:ok, %{phase: :unknown, terminal: :unavailable}} = Control.status(control))

    assert phase.generation == endpoint.generation
    assert phase.phase == if(victim == :router, do: :retired, else: :unknown)
    assert remaining(deadline) > 0

    assert {:error, %{certainty: :no_write}} =
             Control.submit(control, Request.field("pid"), timeout: 500)

    if victim in [:manager, :root] do
      assert {:error, %{certainty: :unknown}} = Operation.result(operation)
    else
      assert {:ok, result} = Operation.result(operation)

      if victim == :router,
        do: assert(result.outcome == :skipped and result.certainty == :no_write)
    end

    assert {"", 0} = OwnedTmux.command(fixture, ["list-clients", "-F", ~S"#{client_pid}"])
    deadline = System.monotonic_time(:millisecond) + 950
    final = [parent | for({_, pid, _, _} <- children(parent, deadline), do: pid)]

    final =
      final ++
        for(
          pid <- final,
          pid != parent,
          {_, child, _, _} <- children(pid, deadline),
          do: child
        )

    cleanup = for pid <- final, is_pid(pid), do: {pid, Process.monitor(pid)}
    assert :ok = :sys.terminate(parent, :normal, remaining(deadline))
    exited(cleanup, deadline)
    assert remaining(deadline) > 0
    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  def start_and_report({module, function, arguments}, observer, token) do
    case apply(module, function, arguments) do
      {:ok, root, _control} = result ->
        send(observer, {token, root})
        result

      other ->
        other
    end
  end

  defp watch_terminal(manager) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {fn
           _state, {:noreply, %{phase: phase}}, _name when phase in [:closed, :unknown] ->
             send(observer, {token, phase})
             :done

           state, _event, _name ->
             state
         end, nil},
        500
      )

    token
  end

  defp inert(root, deadline) do
    children = children(root, deadline)
    {_, manager, _, _} = Enum.find(children, &(elem(&1, 0) == LibTmux.Control.Manager))
    {_, host, _, _} = Enum.find(children, &(elem(&1, 0) == LibTmux.Control.EpochHost))
    state = :sys.get_state(manager, remaining(deadline))
    assert state.phase == :unknown and state.unclean
    assert is_nil(state.births) and is_nil(state.pending)
    assert Enum.all?(state.actors, fn {_role, pid} -> is_nil(pid) end)
    assert children(host, deadline) == []
  end

  defp exited(monitors, deadline) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, remaining(deadline)
      refute Process.alive?(pid)
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp children(supervisor, deadline),
    do: :gen_server.call(supervisor, :which_children, remaining(deadline))
end
