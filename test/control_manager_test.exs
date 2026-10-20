defmodule LibTmux.ControlManagerTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}

  alias LibTmux.Control.{
    Admission,
    Births,
    EpochSupervisor,
    Inbox,
    Lifetime,
    Manager,
    Records,
    Request
  }

  alias LibTmux.Test.NativeDriver
  @moduletag :capture_log

  @tag public_start_reason: true
  test "a readiness waiter registered after startup failure retains the original reason" do
    {_host, view, _lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    current = endpoint(view)
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(manager, {
        fn
          _seen, {:noreply, %{reason: :invalid_bootstrap}}, _name ->
            send(observer, {:startup_failed, token})
            :done

          seen, _event, _name ->
            seen
        end,
        false
      })

    assert_receive {:driver_open, guardian, handle}, 200
    assert_receive {:driver_command, ^guardian, ^handle, <<?O, _::binary>>}, 200
    peer = %{guardian: guardian, handle: handle}
    send(guardian, {handle, {:data, <<?S, 123::32>>}})
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 2, _::binary>>}, 200
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 1, _::binary>>}, 200
    data(peer, "%begin 1 1 0\nunexpected attach output\n%end 1 1 0\n")
    assert_receive {:startup_failed, ^token}, 200

    try do
      waiting = metadata(current, current.epoch, {:connection, :ready})

      assert {:error, %Error{kind: :invalid_bootstrap, certainty: :unknown}} =
               result(current, waiting)
    after
      retire(peer)
    end
  end

  @tag lifecycle_waits: true
  @tag ready_settlement: true
  test "one failed readiness settlement prevents success for the next intact waiter" do
    {_host, view, _lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    initial = endpoint(view)
    first = metadata(initial, initial.epoch, {:connection, :ready})
    second = metadata(initial, initial.epoch, {:connection, :ready})
    assert [^second, ^first] = :sys.get_state(manager, 500).ready_waiting
    :ets.delete(initial.inbox.table, second.slot)
    peer = bootstrap(view)

    try do
      assert {:error, %Error{kind: :cleanup_unknown, certainty: :unknown}} =
               result(initial, first)

      assert %{phase: :unknown} = Lifetime.status(initial.lifetime)
      assert %{phase: :unknown, metadata_fault: true} = :sys.get_state(manager, 500)
    after
      LibTmux.Transport.Reply.close(second.reply, second.token)
      retire(peer)
    end
  end

  for initial_phase <- [:closed, :unknown] do
    @tag lifecycle_waits: true
    @tag initial_wait_phase: initial_phase
    test "readiness wait cannot start an inert #{initial_phase} lifetime", %{
      initial_wait_phase: phase
    } do
      {host, view, lifetime, options} = setup_manager()

      if phase == :closed do
        {:ok, 1} = Lifetime.begin_epoch(lifetime)
        :ok = Lifetime.revoke(lifetime, 1)
        :ok = Lifetime.retired(lifetime, 1)
      else
        :ok = Lifetime.abandon_initial(lifetime)
      end

      before = Lifetime.status(lifetime)
      start_supervised!({Manager, options})
      current = endpoint(view)
      ready = metadata(current, current.epoch, {:connection, :ready})
      assert {:error, %Error{kind: kind, certainty: :unknown}} = result(current, ready)
      assert kind == if(phase == :closed, do: :not_ready, else: :cleanup_unknown)
      assert before == Lifetime.status(lifetime)
      assert [] = Supervisor.which_children(host)
      refute_receive {:driver_open, _, _}, 0
    end
  end

  @tag lifecycle_waits: true
  test "retirement waits require terminal native proof and actual actor exit" do
    {_host, view, lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    initial = endpoint(view)
    waiting = metadata(initial, initial.epoch, {:connection, :ready})
    peer = bootstrap(view)
    ready = result(initial, waiting)
    early = metadata(ready, ready.epoch, {:connection, :retired})
    assert {:error, %Error{kind: :not_closing}} = result(ready, early)
    accounting_turn(manager)

    assert :ok = Lifetime.revoke(lifetime, ready.generation)
    retired = metadata(ready, ready.epoch, {:connection, :retired})
    assert :sys.get_state(manager, 500).phase == :closing
    assert :pending = Inbox.result(ready.inbox, retired)
    %{guardian: guardian, handle: handle} = peer
    monitor = Process.monitor(guardian)
    assert_receive {:driver_command, ^guardian, ^handle, "Q"}, 200
    send(guardian, {handle, {:data, <<?E, 1, 0::32>>}})
    assert_receive {:driver_command, ^guardian, ^handle, "T"}, 200
    assert :pending = Inbox.result(ready.inbox, retired)
    send(guardian, {handle, {:exit_status, 0}})
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 200
    assert :ok = result(ready, retired)
    assert %{phase: :retired} = Lifetime.status(lifetime)
    assert :sys.get_state(manager, 500).phase == :closed
  end

  @tag lifecycle_waits: true
  test "lost cleanup cannot settle a retirement watch as success" do
    {_host, view, lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    initial = endpoint(view)
    waiting = metadata(initial, initial.epoch, {:connection, :ready})
    peer = bootstrap(view)
    ready = result(initial, waiting)
    assert :ok = Lifetime.revoke(lifetime, ready.generation)
    retired = metadata(ready, ready.epoch, {:connection, :retired})
    assert :sys.get_state(manager, 500).phase == :closing
    monitor = Process.monitor(peer.guardian)
    Process.exit(peer.guardian, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 200
    assert {:error, %Error{kind: :cleanup_unknown, certainty: :unknown}} = result(ready, retired)
    assert %{phase: :unknown} = Lifetime.status(lifetime)
  end

  @tag lifecycle_waits: true
  test "a higher-slot retirement watch settles before a lower-slot reconnect" do
    {_host, view, lifetime, options} = setup_manager()
    {:ok, 1} = Lifetime.begin_epoch(lifetime)
    :ok = Lifetime.revoke(lifetime, 1)
    :ok = Lifetime.retired(lifetime, 1)
    manager = start_supervised!({Manager, options})
    old = endpoint(view)
    :ok = :sys.suspend(manager, 500)

    {reconnect, retired} =
      try do
        reconnect = metadata(old, old.epoch, {:reconnect, nil})
        retired = metadata(old, old.epoch, {:connection, :retired})
        assert reconnect.slot < retired.slot
        {reconnect, retired}
      after
        :sys.resume(manager, 500)
      end

    assert :ok = result(old, retired)
    peer = bootstrap(view)
    ready = result(old, reconnect)
    assert ready.generation == 2
    accounting_turn(manager)
    assert :ok = Lifetime.revoke(lifetime, ready.generation)
    ending = metadata(ready, ready.epoch, {:connection, :retired})
    retire(peer)
    assert :ok = result(ready, ending)
  end

  for loss <- [:shutdown, :host_down] do
    @tag initial_owner_loss: loss
    test "a generation-zero fence keeps Manager inert through #{loss}", %{
      initial_owner_loss: loss
    } do
      {host, view, lifetime, options} = setup_manager()
      assert :ok = Lifetime.abandon_initial(lifetime)
      manager = start_supervised!({Manager, options})

      assert %{phase: :unknown, generation: 0, unclean: true, pending: nil} =
               :sys.get_state(manager, 500)

      assert [] = Supervisor.which_children(host)
      current = endpoint(view)
      reconnecting = metadata(current, current.epoch, {:reconnect, nil})
      assert {:error, %Error{kind: :cleanup_unknown}} = result(current, reconnecting)
      assert %{generation: 0, phase: :unknown} = Lifetime.status(lifetime)

      if loss == :shutdown do
        monitor = Process.monitor(manager)
        assert :ok = stop_supervised(Manager)
        assert_receive {:DOWN, ^monitor, :process, ^manager, :shutdown}, 100
      else
        monitor = Process.monitor(host)
        assert :ok = stop_supervised(:host)
        assert_receive {:DOWN, ^monitor, :process, ^host, :shutdown}, 100
        accounting_turn(manager)
        assert %{phase: :unknown, generation: 0} = :sys.get_state(manager, 500)
      end

      assert %{generation: 0, phase: :unknown} = Lifetime.status(lifetime)
      refute_receive {:driver_open, _, _}, 0
    end
  end

  test "closure between Router creation and Guardian startup retires without native uncertainty" do
    {host, _view, lifetime, options} = setup_manager()
    :ok = :sys.suspend(host, 500)
    manager = start_supervised!({Manager, options})
    gate = gate_reply(manager, 1)

    try do
      :ok = :sys.resume(host, 500)
      assert_receive {:startup_created, ^gate, router}, 200
      monitor = Process.monitor(router)
      :ok = Lifetime.revoke(lifetime, 1)
      send(manager, {gate, :continue})
      assert_receive {:DOWN, ^monitor, :process, ^router, _reason}, 200
      assert_receive {:cleanly_closed, ^gate}, 200
      assert %{generation: 1, phase: :retired} = Lifetime.status(lifetime)
      assert [] = Supervisor.which_children(host)
      refute_receive {:driver_open, _, _}, 0
    after
      send(manager, {gate, :continue})
      :sys.resume(host, 500)
    end
  end

  test "closure after Guardian creation binds the captured actors and waits for native retirement" do
    {host, view, lifetime, options} = setup_manager()
    :ok = :sys.suspend(host, 500)
    manager = start_supervised!({Manager, options})
    gate = gate_reply(manager, 2)

    try do
      :ok = :sys.resume(host, 500)
      assert_receive {:startup_created, ^gate, guardian}, 200
      assert_receive {:driver_open, ^guardian, handle}
      assert_receive {:driver_command, ^guardian, ^handle, <<?O, _::binary>>}
      %{births: births} = endpoint(view)
      {:ok, %{roles: %{router: router}}} = Births.snapshot(births)
      monitor = Process.monitor(router)
      :ok = Lifetime.revoke(lifetime, 1)
      send(manager, {gate, :continue})
      retire(%{guardian: guardian, handle: handle})
      assert_receive {:DOWN, ^monitor, :process, ^router, :normal}, 200
      assert_receive {:cleanly_closed, ^gate}, 200
      assert %{generation: 1, phase: :retired} = Lifetime.status(lifetime)
      assert [] = Supervisor.which_children(host)
    after
      send(manager, {gate, :continue})
      :sys.resume(host, 500)
    end
  end

  test "closed EpochSupervisor startup reports its intended error without a callback violation" do
    {host, _view, lifetime, _options} = setup_manager()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    births = Births.new(lifetime, generation, make_ref(), Deadline.new(500))
    {:ok, _roles} = Births.close(births)

    assert {:error, {%Error{kind: :startup_closed}, _child}} =
             Supervisor.start_child(host, EpochSupervisor.child_spec(births))

    assert [] = Supervisor.which_children(host)
  end

  test "retained outcomes survive reconnect until forget or expiry and reconnect keeps its deadline" do
    {_host, view, lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, Keyword.put(options, :retention_ms, 1)})
    caller = self()

    :ok =
      :sys.install(
        manager,
        {fn
           phase, {:in, {:router, _epoch, _router, {:settled, lease}}}, _name ->
             send(caller, {:operation_settled, lease})
             phase

           phase, {:noreply, %{phase: next, generation: generation}}, _name when phase != next ->
             send(caller, {:manager_phase, next, generation})
             next

           phase, _event, _name ->
             phase
         end, :starting},
        500
      )

    first = endpoint(view)
    ticket = metadata(first, first.epoch, {:reconnect, nil})
    peer = bootstrap(view)
    first = result(first, ticket)
    lease = submit(first, 500)
    complete(peer, lease)
    assert {:ok, retained} = Records.fetch(first.records, lease)
    assert retained.life.result.lines == ["v1:retained"]

    :ok = Lifetime.revoke(lifetime, first.generation)
    ticket = metadata(first, first.epoch, {:reconnect, nil})
    retire(peer)
    next_peer = bootstrap(view)
    second = result(first, ticket)
    assert second.generation == first.generation + 1
    assert {:ok, ^retained} = Records.fetch(second.records, lease)

    ticket = metadata(second, lease.epoch, {:forget, lease})
    assert :ok = result(second, ticket)
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(second.records, lease)
    accounting_turn(manager)
    replacement = submit(second, 75)
    assert replacement.slot == lease.slot and replacement.generation > lease.generation
    complete(next_peer, replacement)

    :ok = Lifetime.revoke(lifetime, second.generation)
    ticket = metadata(second, second.epoch, {:reconnect, nil}, 125)
    assert {:error, %Error{kind: :timeout}} = result(second, ticket)
    assert %{generation: 2, phase: :closing} = Lifetime.status(lifetime)
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(second.records, replacement)
    refute_receive {:driver_open, _, _}, 0
    retire(next_peer)
    assert_receive {:manager_phase, :closed, 2}, 200
    assert %{phase: :closed, generation: 2} = :sys.get_state(manager, 500)
    refute_receive {:driver_open, _, _}, 0
  end

  test "Manager retains an early waiter result through explicit record forget" do
    {_host, view, _lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, Keyword.put(options, :waiter_capacity, 1)})
    initial = endpoint(view)
    connecting = metadata(initial, initial.epoch, {:reconnect, nil})
    peer = bootstrap(view)
    ready = result(initial, connecting)
    caller = self()

    :ok =
      :sys.install(
        manager,
        {fn
           state, {:in, {:router, _epoch, _router, {:settled, lease}}}, _name ->
             send(caller, {:wire_retired, lease})
             state

           state, _event, _name ->
             state
         end, nil},
        500
      )

    lease = submit(ready, 500)
    %{guardian: guardian, handle: handle} = peer
    assert_receive {:driver_command, ^guardian, ^handle, <<?W, 1::32, line::binary>>}

    {:ok, ticket} =
      Inbox.publish(ready.waiter_inbox, ready.epoch, Deadline.new(500), {:await, lease})

    :ok = Inbox.notify(ready.waiter_inbox)
    data(peer, "%begin 1 4 1\nv1:early\n%end 1 4 1\n")
    token = ticket.token
    assert_receive {^token, :ready}, 200
    assert {:ok, {:ok, retained}} = Inbox.result(ready.waiter_inbox, ticket)
    assert retained.lines == ["v1:early"]
    assert {:ok, %{life: %{wire: :writing}}} = Records.fetch(ready.records, lease)
    send(guardian, {handle, {:data, <<?A, 1::32, byte_size(line)::16, 0>>}})
    assert_receive {:wire_retired, ^lease}, 200
    forgetting = metadata(ready, lease.epoch, {:forget, lease})
    assert :ok = result(ready, forgetting)
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(ready.records, lease)
    assert {:ok, {:ok, ^retained}} = Inbox.result(ready.waiter_inbox, ticket)
    replacement = submit(ready, 500)
    assert replacement.slot == lease.slot and replacement.generation > lease.generation

    assert {:error, %Error{kind: :resource_limit}} =
             Inbox.publish(
               ready.waiter_inbox,
               ready.epoch,
               Deadline.new(500),
               {:await, replacement}
             )

    assert :ok = Inbox.close(ready.waiter_inbox, ticket)
    :ok = Lifetime.revoke(ready.lifetime, ready.generation)
    retire(peer)
  end

  test "lost waiter storage blocks reconnect before advancing a closed generation" do
    {_host, view, lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    initial = endpoint(view)
    connecting = metadata(initial, initial.epoch, {:reconnect, nil})
    peer = bootstrap(view)
    ready = result(initial, connecting)
    observer = self()
    closed = make_ref()

    :ok =
      :sys.install(
        manager,
        {fn
           _state, {:noreply, %{phase: :closed}}, _name ->
             send(observer, {:closed, closed})
             :done

           state, _event, _name ->
             state
         end, nil},
        500
      )

    :ok = Lifetime.revoke(lifetime, ready.generation)
    retire(peer)
    assert_receive {:closed, ^closed}, 200

    :sys.replace_state(
      manager,
      fn state ->
        :ets.delete(state.waiters.inbox.table)
        state
      end,
      500
    )

    reconnecting = metadata(ready, ready.epoch, {:reconnect, nil})
    assert {:error, %Error{kind: :cleanup_unknown}} = result(ready, reconnecting)
    assert Lifetime.status(lifetime).generation == ready.generation
    assert :sys.get_state(manager, 500).phase == :unknown
    refute_receive {:driver_open, _, _}, 0
  end

  test "lost waiter storage prevents a queued readiness event from publishing a connected endpoint" do
    {_host, view, lifetime, options} = setup_manager()
    manager = start_supervised!({Manager, options})
    initial = endpoint(view)
    connecting = metadata(initial, initial.epoch, {:reconnect, nil})

    :ok =
      :sys.install(
        manager,
        {fn
           state, {:in, {:router, _epoch, _router, {:ready, _instance}}}, _name ->
             :ets.delete(initial.waiter_inbox.table)
             state

           state, _event, _name ->
             state
         end, nil},
        500
      )

    peer = bootstrap(view)

    assert {:error, %Error{kind: :waiter_failed, certainty: :unknown}} =
             result(initial, connecting)

    assert :sys.get_state(manager, 500).phase == :unknown
    assert Lifetime.status(lifetime).phase == :unknown
    retire(peer)
  end

  for storage_lost <- [false, true] do
    @tag waiter_storage_lost: storage_lost
    test "automatic record expiry preserves accepted evidence after suspension (storage lost: #{storage_lost})",
         %{waiter_storage_lost: storage_lost} do
      {_host, view, _lifetime, options} = setup_manager()
      manager = start_supervised!({Manager, Keyword.put(options, :retention_ms, 1)})
      initial = endpoint(view)
      connecting = metadata(initial, initial.epoch, {:reconnect, nil})
      peer = bootstrap(view)
      ready = result(initial, connecting)
      request = Request.field("pid")
      {:ok, line} = Request.encode(request, ready.instance)

      {:ok, lease} =
        Admission.claim(ready.pool, ready.epoch, ready.router, Deadline.new(150), byte_size(line))

      {:ok, ticket} =
        Inbox.publish(ready.waiter_inbox, ready.epoch, Deadline.new(500), {:await, lease})

      :ok = Inbox.notify(ready.waiter_inbox)
      assert map_size(:sys.get_state(manager, 500).waiters.active) == 1
      observer = self()

      :ok =
        :sys.install(
          ready.router,
          {fn
             _seen, {:in, {:submit, _epoch, ^lease, _request}}, _name ->
               true

             true, {:noreply, %{operations: operations}}, _name when map_size(operations) == 0 ->
               send(observer, :retired_while_manager_paused)
               :done

             seen, _event, _name ->
               seen
           end, false},
          500
        )

      :ok = :sys.suspend(manager, 500)

      try do
        send(ready.router, {:submit, ready.epoch, lease, request})
        %{guardian: guardian, handle: handle} = peer
        assert_receive {:driver_command, ^guardian, ^handle, <<?W, 1::32, line::binary>>}
        data(peer, "%begin 1 4 1\nv1:expired-record\n%end 1 4 1\n")
        send(guardian, {handle, {:data, <<?A, 1::32, byte_size(line)::16, 0>>}})
        assert_receive :retired_while_manager_paused, 200

        if storage_lost do
          :sys.replace_state(
            manager,
            fn state ->
              :ets.delete(state.waiters.inbox.table)
              state
            end,
            500
          )
        end

        timer =
          :erlang.start_timer(
            max(lease.expires_at + 2 - System.monotonic_time(:millisecond), 0),
            self(),
            :retention_due
          )

        assert_receive {:timeout, ^timer, :retention_due}, 200
      after
        :sys.resume(manager, 500)
      end

      if storage_lost do
        accounting_turn(manager)
        assert :sys.get_state(manager, 500).phase == :unknown
        assert Lifetime.status(ready.lifetime).phase == :unknown

        assert {:ok,
                %{life: %{result: %{lines: ["v1:expired-record"], certainty: :acknowledged}}}} =
                 Records.fetch(ready.records, lease)

        refute_receive {:driver_open, _, _}, 0
      else
        token = ticket.token
        assert_receive {^token, :ready}, 200
        accounting_turn(manager)
        assert {:error, %Error{kind: :stale_operation}} = Records.fetch(ready.records, lease)

        assert {:ok, {:ok, %{lines: ["v1:expired-record"], certainty: :acknowledged}}} =
                 Inbox.result(ready.waiter_inbox, ticket)

        :ok = Lifetime.revoke(ready.lifetime, ready.generation)
      end

      Inbox.close(ready.waiter_inbox, ticket)
      retire(peer)
    end
  end

  test "a suspended host cannot block reserved closure or admit its queued late startup" do
    {host, view, lifetime, options} = setup_manager()
    :ok = :sys.suspend(host, 500)

    try do
      manager = start_supervised!({Manager, options})
      assert %{phase: :starting, generation: 1} = :sys.get_state(manager, 500)
      [{:connection, endpoint}] = :ets.lookup(view, :connection)
      assert :ok = Lifetime.revoke(lifetime, 1)

      {:ok, ticket} =
        Inbox.publish(endpoint.inbox, endpoint.epoch, Deadline.new(500), {:reconnect, nil})

      :ok = Inbox.notify(endpoint.inbox)
      token = ticket.token
      assert_receive {^token, :ready}, 200

      assert {:ok, {:error, %Error{kind: :cleanup_unknown}}} =
               Inbox.result(endpoint.inbox, ticket)

      :ok = Inbox.close(endpoint.inbox, ticket)
      assert %{phase: :unknown} = :sys.get_state(manager, 500)
      assert %{phase: :unknown} = Lifetime.status(lifetime)
      :ok = :sys.resume(host, 500)
      barrier = :gen_server.send_request(host, :which_children)
      assert {:reply, []} = :gen_server.receive_response(barrier, 500)
      refute_receive {:driver_open, _, _}, 0
      assert %{phase: :unknown} = :sys.get_state(manager, 500)
    after
      :sys.resume(host, 500)
    end
  end

  test "restarting Manager preserves the unclean lifetime and never starts another epoch" do
    {host, view, lifetime, options} = setup_manager()
    :ok = :sys.suspend(host, 500)

    try do
      first = start_supervised!({Manager, options})
      assert %{generation: 1} = :sys.get_state(first, 500)
      [{:connection, old}] = :ets.lookup(view, :connection)
      monitor = Process.monitor(first)
      stop_supervised!(Manager)
      assert_receive {:DOWN, ^monitor, :process, ^first, :shutdown}
      second = start_supervised!({Manager, options})
      assert %{phase: :unknown, generation: 1} = :sys.get_state(second, 500)
      [{:connection, current}] = :ets.lookup(view, :connection)
      assert current.manager == second and current.manager != old.manager
      assert %{phase: :unknown, generation: 1} = Lifetime.status(lifetime)

      {:ok, ticket} =
        Inbox.publish(current.inbox, current.epoch, Deadline.new(500), {:reconnect, nil})

      :ok = Inbox.notify(current.inbox)
      token = ticket.token
      assert_receive {^token, :ready}, 200
      assert {:ok, {:error, %Error{kind: :cleanup_unknown}}} = Inbox.result(current.inbox, ticket)
      :ok = Inbox.close(current.inbox, ticket)
      :ok = :sys.resume(host, 500)
      barrier = :gen_server.send_request(host, :which_children)
      assert {:reply, []} = :gen_server.receive_response(barrier, 500)
      refute_receive {:driver_open, _, _}, 0
    after
      :sys.resume(host, 500)
    end
  end

  defp setup_manager do
    host =
      start_supervised!(%{
        id: :host,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    view = :ets.new(:view, [:set, :public])
    lifetime = Lifetime.new()

    {host, view, lifetime,
     [
       host: host,
       view: view,
       lifetime: lifetime,
       deadline: Deadline.new(500),
       payload: <<0>>,
       driver: {NativeDriver, observer: self()},
       capacity: 2,
       metadata_capacity: 2
     ]}
  end

  defp endpoint(view) do
    [{:connection, endpoint}] = :ets.lookup(view, :connection)
    endpoint
  end

  defp gate_reply(manager, index) do
    caller = self()
    gate = make_ref()

    debug = fn
      ^index, {:in, {[:alias | _], {:ok, pid}}}, _name ->
        send(caller, {:startup_created, gate, pid})

        receive do
          {^gate, :continue} -> :watch_closed
        after
          500 -> exit(:test_gate_timeout)
        end

      count, {:in, {[:alias | _], {:ok, _pid}}}, _name when is_integer(count) ->
        count + 1

      :watch_closed, {:noreply, %{phase: :closed}}, _name ->
        send(caller, {:cleanly_closed, gate})
        :done

      count, _event, _name ->
        count
    end

    :ok = :sys.install(manager, {debug, 0}, 500)
    gate
  end

  defp accounting_turn(manager) do
    caller = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {fn
           _seen, {:in, :sweep}, _name ->
             true

           true, {:noreply, _state}, _name ->
             send(caller, {:accounted, token})
             :done

           seen, _event, _name ->
             seen
         end, false},
        500
      )

    assert_receive {:accounted, ^token}, 100
  end

  defp metadata(endpoint, epoch, request, timeout \\ 500) do
    {:ok, ticket} = Inbox.publish(endpoint.inbox, epoch, Deadline.new(timeout), request)
    :ok = Inbox.notify(endpoint.inbox)
    ticket
  end

  defp result(endpoint, ticket) do
    token = ticket.token

    try do
      assert_receive {^token, :ready}, 500
      assert {:ok, outcome} = Inbox.result(endpoint.inbox, ticket)

      case outcome do
        {:ok, ready} -> ready
        other -> other
      end
    after
      Inbox.close(endpoint.inbox, ticket)
    end
  end

  defp bootstrap(view) do
    assert_receive {:driver_open, guardian, handle}, 200
    assert_receive {:driver_command, ^guardian, ^handle, <<?O, _::binary>>}
    %{births: births, epoch: epoch} = endpoint(view)
    {:ok, %{roles: %{router: router}}} = Births.snapshot(births)
    peer = %{guardian: guardian, handle: handle, epoch: epoch}
    send(guardian, {handle, {:data, <<?S, 123::32>>}})
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 2, _::binary>>}
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 1, _::binary>>}
    pid = System.pid()
    data(peer, "%begin 1 1 0\n%end 1 1 0\n%begin 1 2 0\n#{pid}\n%end 1 2 0\n")
    assert_receive {:driver_command, ^guardian, ^handle, <<?W, 0::32, line::binary>>}
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 1, _::binary>>}
    nonce = :sys.get_state(router, 500).bootstrap.nonce
    data(peer, "%begin 1 3 1\n#{nonce}:#{pid}\n%end 1 3 1\n")
    send(guardian, {handle, {:data, <<?A, 0::32, byte_size(line)::16, 0>>}})
    peer
  end

  defp submit(endpoint, timeout) do
    request = Request.field("pid")
    {:ok, line} = Request.encode(request, endpoint.instance)

    {:ok, lease} =
      Admission.claim(
        endpoint.pool,
        endpoint.epoch,
        endpoint.router,
        Deadline.new(timeout),
        byte_size(line)
      )

    send(endpoint.router, {:submit, endpoint.epoch, lease, request})
    lease
  end

  defp complete(peer, lease) do
    %{guardian: guardian, handle: handle} = peer
    assert_receive {:driver_command, ^guardian, ^handle, <<?W, 1::32, line::binary>>}
    data(peer, "%begin 1 4 1\nv1:retained\n%end 1 4 1\n")
    send(guardian, {handle, {:data, <<?A, 1::32, byte_size(line)::16, 0>>}})
    assert_receive {:operation_settled, ^lease}
  end

  defp data(peer, bytes),
    do: send(peer.guardian, {peer.handle, {:data, <<?D, 1, bytes::binary>>}})

  defp retire(peer) do
    %{guardian: guardian, handle: handle} = peer
    monitor = Process.monitor(guardian)
    assert_receive {:driver_command, ^guardian, ^handle, "Q"}, 200
    send(guardian, {handle, {:data, <<?E, 1, 0::32>>}})
    assert_receive {:driver_command, ^guardian, ^handle, "T"}
    send(guardian, {handle, {:exit_status, 0}})
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}
  end
end
