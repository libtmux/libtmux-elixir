defmodule LibTmux.ControlPartialWriteIntegrationTest do
  use ExUnit.Case,
    async: true,
    parameterize: [%{after_fragment: :continue}, %{after_fragment: :stop}]

  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason:
               "Qualifies awaiter death and epoch cancellation between native-confirmed fragments"

  test "awaiter death between native-confirmed fragments preserves line ownership", %{
    after_fragment: action
  } do
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
                 capacity: 2,
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
    gate = gate_fragment(roles.router, endpoint.epoch, roles.guardian)
    deadline = Deadline.new(800)
    value = String.duplicate("x", 12_000)

    try do
      assert {:ok, operation} =
               Control.submit(control, Request.set_user_option("@partial_prefix", value),
                 timeout: Deadline.remaining(deadline)
               )

      lease = operation.lease
      assert_receive {^gate, :fragment, ^lease, count}, Deadline.remaining(deadline)
      assert count > 0 and count < lease.bytes
      assert {:ok, %{wire: :writing, result: nil}} = Operation.status(operation)

      assert {:ok, sibling} =
               Control.submit(control, Request.set_user_option("@partial_sibling", "second"),
                 timeout: Deadline.remaining(deadline)
               )

      observer = self()

      {awaiter, monitor} =
        spawn_monitor(fn ->
          receive do
            :await ->
              send(observer, {:await_returned, Operation.await(operation, timeout: 800)})
          end
        end)

      on_exit(fn -> Process.exit(awaiter, :kill) end)
      waiter = watch_waiter(endpoint.manager, awaiter)
      send(awaiter, :await)
      assert_receive {^waiter, :registered}, Deadline.remaining(deadline)
      Process.exit(awaiter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^awaiter, :killed}, Deadline.remaining(deadline)
      assert_receive {^waiter, :released}, Deadline.remaining(deadline)
      assert Operation.result(operation) == :pending
      assert Operation.result(sibling) == :pending
      assert {:ok, %{phase: :ready}} = Control.status(control)

      native = OwnedTmux.watch_processes([helper, guardian.child])

      if action == :stop do
        assert :ok = Operation.stop(operation)
        assert {:ok, %{phase: :closing, generation: generation}} = Control.status(control)
        assert generation == endpoint.generation
      end

      send(roles.router, {gate, :continue})

      if action == :continue do
        receipt = watch_receipt(endpoint.manager, endpoint.waiter_inbox)

        assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
                 Operation.await(operation, timeout: Deadline.remaining(deadline))

        assert_receive {^receipt, :released}, Deadline.remaining(deadline)

        assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
                 Operation.await(sibling, timeout: Deadline.remaining(deadline))

        assert {value <> "\n", 0} ==
                 OwnedTmux.command(fixture, ["show-options", "-sv", "@partial_prefix"])

        assert {"second\n", 0} =
                 OwnedTmux.command(fixture, ["show-options", "-sv", "@partial_sibling"])
      end

      assert Deadline.remaining(deadline) > 0
      cleanup = Deadline.new(950)
      assert :ok = Control.close(control, timeout: min(800, Deadline.remaining(cleanup)))

      if action == :stop do
        assert {:ok, %{wire: :retired, result: %{outcome: :unknown, certainty: :unknown}}} =
                 Operation.status(operation)

        assert {:ok, %{outcome: :skipped, certainty: :no_write}} = Operation.result(sibling)

        for name <- ["@partial_prefix", "@partial_sibling"] do
          assert {"", 0} = OwnedTmux.command(fixture, ["show-options", "-sqv", name])
        end
      end

      refute_receive {:await_returned, _result}, 0
      assert :ok = OwnedTmux.await_exit(native)
      assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))

      for {pid, ref} <- monitors do
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, Deadline.remaining(cleanup)
        refute Process.alive?(pid)
      end

      assert Deadline.remaining(cleanup) > 0
      assert OwnedTmux.alive?(fixture)
      assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
    after
      send(roles.router, {gate, :continue})
    end
  end

  defp gate_fragment(router, epoch, guardian) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        router,
        {token,
         fn
           nil,
           {:in, {:guardian, ^epoch, ^guardian, {:written, _operation, lease, count}}},
           _name ->
             send(observer, {token, :fragment, lease, count})

             receive do
               {^token, :continue} -> :done
             after
               800 -> raise "partial-write observation gate was not released"
             end

           previous, _event, _name ->
             previous
         end, nil},
        500
      )

    token
  end

  defp watch_receipt(manager, inbox) do
    [{1, %{state: :free, generation: baseline}}] = :ets.lookup(inbox.table, 1)
    expected = baseline + 1
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           previous, {:noreply, state}, _name ->
             case :ets.lookup(state.waiters.inbox.table, 1) do
               [{1, %{state: :free, generation: ^expected}}] ->
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
