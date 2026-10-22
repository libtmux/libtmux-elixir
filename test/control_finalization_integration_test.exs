defmodule LibTmux.ControlFinalizationIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason: "Qualifies public close and reconnect while epoch finalization is suspended"

  test "expired reconnect cannot attach after suspended finalization resumes" do
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

    assert {:ok, root, control} =
             Supervisor.start_child(
               parent,
               Control.child_spec(
                 server: server,
                 session: {:existing, "$0"},
                 lane: :host_qualified,
                 timeout: 800,
                 capacity: 1,
                 metadata_capacity: 4,
                 waiter_capacity: 1
               )
             )

    first = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    assert {:ok, %{roles: roles}} = Births.snapshot(first.births)
    original = monitor_actors(Map.values(roles))
    persistent = monitor_actors([parent, root, host, first.manager])

    assert {:ok, operation} =
             Control.submit(control, Request.set_user_option("@finalization", "original"),
               timeout: 800
             )

    assert {:ok, %{outcome: :completed, certainty: :acknowledged} = result} =
             Operation.await(operation, timeout: 800)

    native = watch_native(roles.guardian)
    token = watch_finalization(first.manager, host, first.generation, first.epoch)
    assert :ok = :sys.suspend(host, 500)
    deadline = Deadline.new(800)

    try do
      assert {:error, %{kind: :timeout, phase: :close, certainty: :unknown}} =
               Control.close(control, timeout: 100)

      assert_receive {^token, :finalization_pending}, Deadline.remaining(deadline)

      assert {:status, ^host, {:module, _module}, [_dictionary, :suspended | _rest]} =
               :sys.get_status(host, Deadline.remaining(deadline))

      assert Process.alive?(roles.epoch_supervisor)
      exited(Map.take(original, [roles.router, roles.guardian]), deadline)
      assert :ok = OwnedTmux.await_exit(native)
      assert {:ok, %{phase: :closing, generation: generation}} = Control.status(control)
      assert generation == first.generation

      assert {:error, %{kind: :timeout, phase: :connect, certainty: :unknown}} =
               Control.reconnect(control, timeout: 100)

      assert_receive {^token, :reconnect_accepted, slot, ticket_generation},
                     Deadline.remaining(deadline)

      assert is_integer(slot) and is_integer(ticket_generation)
      assert {:ok, %{phase: :closing, generation: ^generation}} = Control.status(control)
      assert {:ok, ^result} = Operation.result(operation)
      assert {"", 0} = clients(fixture)
      assert OwnedTmux.alive?(fixture)
      assert Deadline.remaining(deadline) > 0
    after
      if Process.alive?(host), do: :sys.resume(host, 500)
    end

    assert :ok = Control.close(control, timeout: Deadline.remaining(deadline))
    assert_receive {^token, :retired_without_replacement}, Deadline.remaining(deadline)
    exited(Map.take(original, [roles.epoch_supervisor]), deadline)
    assert {:ok, %{phase: :retired, generation: generation}} = Control.status(control)
    assert generation == first.generation
    assert {"", 0} = clients(fixture)
    assert {:ok, ^result} = Operation.result(operation)
    assert Deadline.remaining(deadline) > 0

    assert {"", 0} =
             OwnedTmux.command(fixture, ["set-option", "-s", "@finalization", "preserved"])

    assert {:ok, replacement} = Control.reconnect(control, timeout: 800)
    second = replacement.endpoint
    assert second.generation == first.generation + 1
    assert second.epoch != first.epoch
    assert second.instance == first.instance
    assert {:ok, %{phase: :ready}} = Control.status(replacement)

    assert {:error, %{kind: :stale_connection, certainty: :no_write}} =
             Control.submit(control, Request.set_user_option("@finalization", "stale"))

    assert {:ok, ^result} = Operation.result(operation)

    assert {"preserved\n", 0} =
             OwnedTmux.command(fixture, ["show-options", "-sv", "@finalization"])

    assert {client_rows, 0} = clients(fixture)
    assert [_client] = String.split(client_rows, "\n", trim: true)
    assert {:ok, %{roles: current_roles}} = Births.snapshot(second.births)
    current = monitor_actors(Map.values(current_roles))
    native = watch_native(current_roles.guardian)
    cleanup = Deadline.new(950)
    assert :ok = Control.close(replacement, timeout: min(800, Deadline.remaining(cleanup)))
    exited(current, cleanup)
    assert :ok = OwnedTmux.await_exit(native)
    assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))
    exited(persistent, cleanup)
    assert Deadline.remaining(cleanup) > 0
    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp clients(fixture),
    do: OwnedTmux.command(fixture, ["list-clients", "-F", ~S"#{client_pid}"])

  defp monitor_actors(pids),
    do: Map.new(pids, fn pid -> {pid, Process.monitor(pid)} end)

  defp exited(monitors, deadline) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end
  end

  defp watch_native(guardian) do
    state = :sys.get_state(guardian, 500)
    {:os_pid, helper} = Port.info(state.handle, :os_pid)
    OwnedTmux.watch_processes([helper, state.child])
  end

  defp watch_finalization(manager, host, generation, epoch) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           :pending,
           {:noreply,
            %{
              phase: :closing,
              generation: ^generation,
              epoch: ^epoch,
              native_retired: true,
              host_finalized: false,
              unclean: false,
              pending: %{kind: :finalize, target: ^host}
            }},
           _name ->
             send(observer, {token, :finalization_pending})
             :reconnect

           :reconnect,
           {:noreply,
            %{phase: :closing, generation: ^generation, epoch: ^epoch, waiting: waiting}},
           _name ->
             case Enum.find(waiting, &(&1.caller == observer and &1.epoch == epoch)) do
               nil ->
                 :reconnect

               ticket ->
                 send(observer, {token, :reconnect_accepted, ticket.slot, ticket.generation})
                 :closed
             end

           :closed,
           {:noreply,
            %{
              phase: :closed,
              generation: ^generation,
              births: nil,
              pending: nil,
              waiting: [],
              ready_waiting: [],
              retiring: []
            }},
           _name ->
             send(observer, {token, :retired_without_replacement})
             :done

           previous, _event, _name ->
             previous
         end, :pending},
        500
      )

    token
  end
end
