defmodule LibTmux.ControlRouterTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error, Ref}
  alias LibTmux.Control.{Admission, Guardian, Lifetime, Records, Request, Router}
  alias LibTmux.Test.NativeDriver

  test "binding replays a buffered Guardian retirement as a terminal event" do
    epoch = make_ref()
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    pool = Admission.new(1)
    records = :ets.new(:records, [:set, :public])

    router =
      start_supervised!(
        {Router,
         manager: self(),
         epoch: epoch,
         lifetime: lifetime,
         generation: generation,
         pool: pool,
         records: records,
         bootstrap: make_ref(),
         deadline: Deadline.new(500)}
      )

    monitor = Process.monitor(router)
    proof = %{cleanup: :retired, proof: :fixture_terminal}
    send(router, {:guardian, epoch, self(), {:retired, proof}})
    send(router, {:bind, self(), epoch, self()})
    assert_receive {:router, ^epoch, ^router, {:retired, ^proof}}
    assert_receive {:DOWN, ^monitor, :process, ^router, :normal}
  end

  test "registered FIFO operations retain replies that precede native write acknowledgement" do
    state = connection()
    first = submit(state, Request.field("pid"))
    second = submit(state, Request.field("pid"))
    assert_receive {:driver_command, _, _, <<?W, 1::32, line::binary>>}
    reply(state, 4, "v1:first")
    refute_receive {:router, _, _, {:settled, _}}, 0
    ack(state, 1, line)
    assert_receive {:driver_command, _, _, <<?W, 2::32, line::binary>>}
    ack(state, 2, line)
    reply(state, 5, "v1:second")
    assert_receive {:router, _, _, {:settled, ^first}}
    assert_receive {:router, _, _, {:settled, ^second}}
    assert %{life: %{result: %{lines: ["v1:first"]}, wire: :retired}} = record(state, first)
    assert %{life: %{result: %{lines: ["v1:second"]}, wire: :retired}} = record(state, second)
    close(state)
  end

  @tag :receive_buffer
  test "late acknowledgements drain qualified results and fence the next production write" do
    for acknowledgement <- [:complete, :partial, :failed] do
      state = connection()
      first = submit(state, Request.field("pid"))
      second = submit(state, Request.set_user_option("@not_sent", "second"))
      assert_receive {:driver_command, _, _, <<?W, 1::32, line::binary>>}
      observer = self()
      marker = make_ref()

      :ok =
        :sys.install(state.router, {
          fn
            seen, {:noreply, %{operations: operations}}, _name ->
              case Map.get(operations, first.slot) do
                %{life: %{result: %{outcome: :completed}, wire: :writing}} ->
                  send(observer, {marker, :qualified})
                  :done

                _other ->
                  seen
              end

            seen, _event, _name ->
              seen
          end,
          false
        })

      data(state, "%begin 1 4 1\nv1:retained\n")
      data(state, "%end 1 4 1\n")
      assert_receive {^marker, :qualified}
      assert :sys.get_state(state.guardian).stdout_demand
      send(state.guardian, {state.handle, {:data, <<?Z, 1>>}})
      assert_receive {:guardian, _, _, {:draining, _origin}}
      assert_receive {:driver_command, _, _, "Q"}
      expected_router = state.router
      expected_epoch = state.epoch

      :ok =
        :sys.install(state.guardian, {
          fn
            _seen,
            {:in, {:write, ^expected_router, ^expected_epoch, _token, ^second, _, _, _}},
            _name ->
              send(observer, {marker, :next_write_requested})
              :done

            seen, _event, _name ->
              seen
          end,
          false
        })

      {count, failed} =
        case acknowledgement do
          :complete -> {byte_size(line), 0}
          :partial -> {2, 0}
          :failed -> {0, 1}
        end

      send(state.guardian, {state.handle, {:data, <<?A, 1::32, count::16, failed>>}})
      retire(state)
      assert_receive {:router, _, _, {:settled, ^first}}
      assert_receive {:router, _, _, {:settled, ^second}}
      assert_receive {:router, _, _, {:retired, _proof}}
      finish(state)

      assert %{life: %{wire: :retired, result: %{outcome: :completed, lines: ["v1:retained"]}}} =
               record(state, first)

      expected = if acknowledgement == :complete, do: :unknown, else: :skipped
      assert %{life: %{wire: :retired, result: %{outcome: ^expected}}} = record(state, second)

      if acknowledgement == :complete,
        do: assert_receive({^marker, :next_write_requested}),
        else: refute_receive({^marker, :next_write_requested}, 0)

      refute_receive {:driver_command, _, _, <<?W, 2::32, _bytes::binary>>}, 0
    end
  end

  test "unsafe or stale requests are rejected before any business write" do
    state = connection()
    {:ok, pane} = Ref.new(:pane, "%0", "wrong-instance")
    request = Request.field("pid", pane)
    assert {:error, %Error{kind: :stale_target}} = Request.encode(request, state.instance)

    assert {:error, %Error{kind: :invalid_command}} =
             Request.encode(%Request{kind: :field, value: "pid}\n%end 1 2 1"}, state.instance)

    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0
    close(state)
  end

  test "a revoked epoch leaves queued publications unconsumed" do
    state = connection()
    :ok = :sys.suspend(state.router)

    lease =
      try do
        lease = submit(state, Request.set_user_option("@queued", String.duplicate("x", 4096)))
        assert :ok = Lifetime.revoke(state.lifetime, state.generation)
        lease
      after
        :ok = :sys.resume(state.router)
      end

    :sys.get_state(state.router)
    assert {:ok, :reserved} = Admission.state(state.pool, lease)
    assert :ets.lookup(state.records, lease.slot) == [{lease.slot, nil}]
    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0
    assert_receive {:router, _, _, {:closing, %Error{kind: :closure_requested}}}
    retire(state)
    assert_receive {:router, _, _, {:retired, _}}
    finish(state)
    assert {:ok, 1} = Records.finalize(state.record_owner, state.epoch, state.router)

    assert {:ok, %{life: %{wire: :retired, result: %{outcome: :skipped, certainty: :no_write}}}} =
             Records.fetch(state.record_owner, lease)
  end

  test "an unacknowledged dispatched line becomes unknown and an unsent sibling is skipped" do
    state = connection()
    first = submit(state, Request.field("pid"))
    second = submit(state, Request.field("pid"))
    assert_receive {:driver_command, _, _, <<?W, 1::32, _line::binary>>}
    send(state.guardian, {:close, self(), state.epoch, :test_close})
    retire(state)
    assert_receive {:router, _, _, {:settled, ^first}}
    assert_receive {:router, _, _, {:settled, ^second}}
    assert %{life: %{result: %{outcome: :unknown, certainty: :unknown}}} = record(state, first)
    assert %{life: %{result: %{outcome: :skipped, certainty: :no_write}}} = record(state, second)
    assert_receive {:router, _, _, {:retired, _}}
    finish(state)
  end

  test "an expired queued slot cannot alias its replacement publication" do
    state = connection()
    first = submit(state, Request.field("pid"))
    expired = submit(state, Request.field("pid"), 100)
    assert_receive {:driver_command, _, _, <<?W, 1::32, first_line::binary>>}
    assert_receive {:router, _, _, {:settled, ^expired}}, 150
    assert %{life: %{result: %{outcome: :skipped}}} = record(state, expired)
    assert :queue.len(:sys.get_state(state.router).queue) == 0
    assert :ok = Admission.release(state.pool, expired)
    replacement = submit(state, Request.field("pid"))
    assert replacement.slot == expired.slot and replacement.generation > expired.generation
    ack(state, 1, first_line)
    assert_receive {:driver_command, _, _, <<?W, 2::32, line::binary>>}
    ack(state, 2, line)
    reply(state, 4, "v1:first")
    assert_receive {:router, _, _, {:settled, ^first}}
    assert_receive {:driver_command, _, _, <<?R, 1, _::binary>>}
    reply(state, 5, "v1:replacement")
    assert_receive {:router, _, _, {:settled, ^replacement}}
    assert %{life: %{result: %{lines: ["v1:replacement"]}}} = record(state, replacement)
    close(state)
  end

  test "complete replies survive malformed tails and native acknowledgement loss" do
    for delivery <- [:same_chunk, :split_chunk, :before_native_ack] do
      state = connection()
      lease = submit(state, Request.field("pid"))
      assert_receive {:driver_command, _, _, <<?W, 1::32, line::binary>>}

      if delivery != :before_native_ack do
        ack(state, 1, line)
        :sys.get_state(state.guardian)
        :sys.get_state(state.router)
      end

      complete = "%begin 1 4 1\nv1:proved\n%end 1 4 1\n"

      if delivery == :split_chunk do
        data(state, complete)
        assert_receive {:router, _, _, {:settled, ^lease}}
        assert_receive {:driver_command, _, _, <<?R, 1, _::binary>>}
        data(state, "%begin broken\n")
      else
        data(state, complete <> "%begin broken\n")
      end

      retire(state)
      if delivery != :split_chunk, do: assert_receive({:router, _, _, {:settled, ^lease}})

      assert %{life: %{result: %{outcome: :completed, lines: ["v1:proved"]}}} =
               record(state, lease)

      assert_receive {:router, _, _, {:retired, _}}
      finish(state)
    end
  end

  test "multiple fragments complete before writer advance and Guardian expires a suspended router" do
    state = connection()
    request = Request.set_user_option("@literal", String.duplicate("x", 6000))
    {:ok, line} = Request.encode(request, state.instance)
    lease = submit(state, request)
    fragments = div(byte_size(line) + 8191, 8192)

    actual =
      for id <- 1..fragments, into: "" do
        assert_receive {:driver_command, _, _, <<?W, ^id::32, fragment::binary>>}
        assert byte_size(fragment) <= 8192
        ack(state, id, fragment)
        fragment
      end

    assert actual == line and fragments > 1
    data(state, "%begin 1 4 1\n%end 1 4 1\n")
    assert_receive {:router, _, _, {:settled, ^lease}}
    assert %{life: %{written: count, result: %{outcome: :completed}}} = record(state, lease)
    assert count == byte_size(line)
    assert :ok = Admission.release(state.pool, lease)

    stopped = submit(state, Request.field("pid"), 150)
    assert_receive {:driver_command, _, _, <<?W, id::32, line::binary>>}
    :ok = :sys.suspend(state.router)

    try do
      ack(state, id, line)
      retire(state)
    after
      if Process.alive?(state.router), do: :sys.resume(state.router)
    end

    assert_receive {:router, _, _, {:settled, ^stopped}}
    assert %{life: %{result: %{outcome: :unknown}}} = record(state, stopped)
    assert_receive {:router, _, _, {:retired, _}}
    finish(state)
  end

  defp connection do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    pool = Admission.new(2)
    records = Records.new(pool)
    epoch = make_ref()
    bootstrap = make_ref()
    deadline = Deadline.new(800)

    router =
      start_supervised!(
        Supervisor.child_spec(
          {Router,
           manager: self(),
           epoch: epoch,
           lifetime: lifetime,
           generation: generation,
           pool: pool,
           records: records.table,
           bootstrap: bootstrap,
           deadline: deadline},
          id: make_ref()
        )
      )

    guardian =
      start_supervised!(
        Supervisor.child_spec(
          {Guardian,
           manager: self(),
           router: router,
           epoch: epoch,
           lifetime: lifetime,
           generation: generation,
           pool: pool,
           bootstrap: bootstrap,
           deadline: deadline,
           payload: <<0>>,
           driver: {NativeDriver, observer: self()}},
          id: make_ref()
        )
      )

    send(router, {:bind, self(), epoch, guardian})
    assert_receive {:driver_open, ^guardian, handle}
    assert_receive {:driver_command, ^guardian, ^handle, <<?O, _::binary>>}

    state = %{
      router: router,
      guardian: guardian,
      handle: handle,
      epoch: epoch,
      pool: pool,
      records: records.table,
      record_owner: records,
      lifetime: lifetime,
      generation: generation,
      router_monitor: Process.monitor(router),
      guardian_monitor: Process.monitor(guardian)
    }

    send(guardian, {handle, {:data, <<?S, 123::32>>}})
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 2, _::binary>>}
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 1, _::binary>>}
    pid = System.pid()
    bytes = "%begin 1 1 0\n%end 1 1 0\n%begin 1 2 0\n" <> pid <> "\n%end 1 2 0\n"
    data(state, bytes)
    assert_receive {:driver_command, ^guardian, ^handle, <<?W, 0::32, line::binary>>}
    nonce = :sys.get_state(router).bootstrap.nonce
    assert_receive {:driver_command, ^guardian, ^handle, <<?R, 1, _::binary>>}
    reply(state, 3, nonce <> ":" <> pid)
    ack(state, 0, line)
    assert_receive {:router, ^epoch, ^router, {:ready, instance}}
    Map.put(state, :instance, instance)
  end

  defp submit(state, request, timeout \\ 500) do
    {:ok, line} = Request.encode(request, state.instance)

    {:ok, lease} =
      Admission.claim(
        state.pool,
        state.epoch,
        state.router,
        Deadline.new(timeout),
        byte_size(line)
      )

    send(state.router, {:submit, state.epoch, lease, request})
    lease
  end

  defp record(state, lease) do
    [{_slot, record}] = :ets.lookup(state.records, lease.slot)
    assert record.lease == lease
    record
  end

  defp reply(state, number, line),
    do: data(state, "%begin 1 #{number} 1\n#{line}\n%end 1 #{number} 1\n")

  defp data(state, bytes),
    do: send(state.guardian, {state.handle, {:data, <<?D, 1, bytes::binary>>}})

  defp ack(state, id, line),
    do: send(state.guardian, {state.handle, {:data, <<?A, id::32, byte_size(line)::16, 0>>}})

  defp close(state) do
    send(state.guardian, {:close, self(), state.epoch, :test_close})
    retire(state)
    assert_receive {:router, _, _, {:retired, _}}
    finish(state)
  end

  defp retire(state) do
    assert_receive {:guardian, _, _, {:closing, _error}}, 200
    assert_receive {:driver_command, _, _, "Q"}
    send(state.guardian, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert_receive {:driver_command, _, _, "T"}
    send(state.guardian, {state.handle, {:exit_status, 0}})
    assert_receive {:guardian, _, _, {:retired, %{cleanup: :retired}}}
  end

  defp finish(state) do
    assert_receive {:DOWN, _, :process, pid, :normal} when pid == state.guardian
    assert_receive {:DOWN, _, :process, pid, :normal} when pid == state.router
    assert :ok = Lifetime.retired(state.lifetime, state.generation)
  end
end
