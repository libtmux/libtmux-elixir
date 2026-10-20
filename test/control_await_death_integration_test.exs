defmodule LibTmux.ControlAwaitDeathIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason: "Qualifies await-caller death without cancelling admitted work"

  test "a dead awaiter releases its only slot while the operation continues" do
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

    endpoint = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    actors = [parent, root, host, endpoint.manager | Map.values(roles)]
    monitors = for pid <- actors, do: {pid, Process.monitor(pid)}
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
    assert :ok = :sys.suspend(roles.router, 500)

    assert {:ok, operation} =
             Control.submit(control, Request.set_user_option("@await_survival", "continued"),
               timeout: 800
             )

    observer = self()

    {awaiter, monitor} =
      spawn_monitor(fn ->
        receive do
          :await -> send(observer, {:await_returned, Operation.await(operation, timeout: 800)})
        end
      end)

    on_exit(fn -> Process.exit(awaiter, :kill) end)
    token = watch_waiter(endpoint.manager, awaiter)
    deadline = Deadline.new(800)
    send(awaiter, :await)
    assert_receive {^token, :registered}, Deadline.remaining(deadline)
    Process.exit(awaiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^awaiter, :killed}, Deadline.remaining(deadline)
    assert_receive {^token, :released}, Deadline.remaining(deadline)
    assert Deadline.remaining(deadline) > 0
    assert Operation.result(operation) == :pending
    assert {:ok, %{phase: :ready, generation: generation}} = Control.status(control)
    assert generation == endpoint.generation

    assert {:error, %{kind: :resource_limit, certainty: :no_write}} =
             Control.submit(control, Request.field("pid"), timeout: Deadline.remaining(deadline))

    assert :ok = :sys.resume(roles.router, Deadline.remaining(deadline))

    assert {:ok, %{outcome: :completed, certainty: :acknowledged} = result} =
             Operation.await(operation, timeout: Deadline.remaining(deadline))

    assert {:ok, ^result} = Operation.result(operation)
    assert Deadline.remaining(deadline) > 0
    refute_receive {:await_returned, _result}, 0

    assert {"continued\n", 0} =
             OwnedTmux.command(fixture, ["show-options", "-sv", "@await_survival"])

    native = OwnedTmux.watch_processes([helper, guardian.child])
    deadline = Deadline.new(950)
    assert :ok = Control.close(control, timeout: min(800, Deadline.remaining(deadline)))
    assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(deadline))

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end

    assert :ok = OwnedTmux.await_exit(native)
    assert Deadline.remaining(deadline) > 0
    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp watch_waiter(manager, receiver) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           nil, {:noreply, state}, _name ->
             case Enum.find(Map.values(state.waiters.active), &(&1.ticket.caller == receiver)) do
               %{ticket: ticket} ->
                 send(observer, {token, :registered})
                 {ticket.slot, ticket.generation}

               nil ->
                 nil
             end

           {slot, generation} = previous, {:noreply, state}, _name ->
             case :ets.lookup(state.waiters.inbox.table, slot) do
               [{^slot, %{state: :free, generation: ^generation}}]
               when state.waiters.active == %{} ->
                 send(observer, {token, :released})
                 :done

               _ ->
                 previous
             end

           previous, _event, _name ->
             previous
         end, nil},
        500
      )

    token
  end
end
