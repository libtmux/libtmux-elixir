defmodule LibTmux.ControlGuardianTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Admission, Guardian, Lifetime}
  alias LibTmux.Test.NativeDriver

  @tag :receive_buffer
  test "router credits release prefetched chunks in order without duplicating native credit" do
    state = guardian() |> activate()
    send(state.pid, {:read, self(), state.epoch, state.credit})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "first">>}})
    assert {:stdout, "first", next} = next_event(state)
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "second">>}})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "third">>}})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {:read, self(), state.epoch, state.credit})
    :sys.get_state(state.pid)
    refute_receive {:guardian, _, _, {:stdout, _, _}}, 0
    refute_receive {:driver_command, _, _, <<?R, 1, _::binary>>}, 0
    send(state.pid, {:read, self(), state.epoch, next})
    assert {:stdout, "second", second} = next_event(state)
    send(state.pid, {:read, self(), state.epoch, next})
    :sys.get_state(state.pid)
    refute_receive {:guardian, _, _, {:stdout, _, _}}, 0
    send(state.pid, {:read, self(), state.epoch, second})
    assert {:stdout, "third", _third} = next_event(state)
    refute_receive {:driver_command, _, _, <<?R, 1, _::binary>>}, 0
    retire(state)
  end

  @tag :receive_buffer
  test "byte and chunk ceilings retire the lane instead of stopping native reads" do
    for {chunk, count} <- [{:binary.copy("x", 8192), 8}, {"x", 128}] do
      state = guardian() |> activate()
      send(state.pid, {:read, self(), state.epoch, state.credit})
      assert_frame(state, <<?R, 1, 8192::16>>)
      send(state.pid, {state.handle, {:data, <<?D, 1, "delivered">>}})
      assert {:stdout, "delivered", _credit} = next_event(state)
      assert_frame(state, <<?R, 1, 8192::16>>)

      for _ <- 1..count do
        send(state.pid, {state.handle, {:data, <<?D, 1, chunk::binary>>}})
        assert_frame(state, <<?R, 1, 8192::16>>)
      end

      refute_receive {:guardian, _, _, {:stdout, _, _}}, 0
      send(state.pid, {state.handle, {:data, <<?D, 1, "overflow">>}})
      assert {:closing, %Error{kind: :resource_limit}} = next_event(state)
      refute Lifetime.allows_write?(state.lifetime, state.generation)
      retire(state, :already_closing)
    end
  end

  @tag :receive_buffer
  test "an end barrier follows queued bytes and late write acknowledgements before retirement" do
    state = guardian() |> activate()
    send(state.pid, {:read, self(), state.epoch, state.credit})
    assert_frame(state, <<?R, 1, 8192::16>>)
    lease = lease(state, 5)
    operation = make_ref()
    send(state.pid, {:write, self(), state.epoch, operation, lease, 0, 5, "noop\n"})
    assert_frame(state, <<?W, 1::32, "noop\n">>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "prefix">>}})
    assert {:stdout, "prefix", first} = next_event(state)
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "tail">>}})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?Z, 1>>}})
    assert {:draining, origin} = next_event(state)
    assert is_integer(origin)
    assert_frame(state, "Q")

    suppressed = lease(state, 5)
    send(state.pid, {:write, self(), state.epoch, make_ref(), suppressed, 0, 5, "noop\n"})
    send(state.pid, {:read, self(), state.epoch, first})
    assert {:stdout, "tail", last} = next_event(state)
    send(state.pid, {:read, self(), state.epoch, last})
    :sys.get_state(state.pid)
    refute_receive {:guardian, _, _, {:drain_end, _}}, 0
    refute_receive {:guardian, _, _, {:closing, _}}, 0
    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0

    send(state.pid, {state.handle, {:data, <<?A, 1::32, 5::16, 0>>}})
    assert {:written, ^operation, ^lease, 5} = next_event(state)
    assert {:drain_end, token} = next_event(state)
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert_frame(state, "T")
    send(state.pid, {state.handle, {:exit_status, 0}})
    send(state.pid, {:drain_ack, self(), state.epoch, make_ref()})
    :sys.get_state(state.pid)
    refute_receive {:guardian, _, _, {:closing, _}}, 0
    refute_receive {:DOWN, _, :process, _, _}, 0

    send(state.pid, {:wire_retired, self(), state.epoch, operation, lease})
    send(state.pid, {:drain_ack, self(), state.epoch, token})
    assert {:wire_retired, ^operation, ^lease} = next_event(state)
    assert {:closing, %Error{kind: :disconnected}} = next_event(state)
    assert {:retired, %{cleanup: :retired}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert :ok = Lifetime.retired(state.lifetime, state.generation)
  end

  @tag :receive_buffer
  test "partial or failed late acknowledgements retain their evidence without claiming a write" do
    for {count, failed, status} <- [{2, 0, :ok}, {2, 1, :error}, {0, 1, :error}] do
      state = guardian() |> activate()
      lease = lease(state, 5)
      send(state.pid, {:write, self(), state.epoch, make_ref(), lease, 0, 5, "noop\n"})
      assert_frame(state, <<?W, 1::32, "noop\n">>)
      send(state.pid, {state.handle, {:data, <<?Z, 1>>}})
      assert {:draining, _origin} = next_event(state)
      assert_frame(state, "Q")
      send(state.pid, {state.handle, {:data, <<?A, 1::32, count::16, failed>>}})
      assert {:drain_end, token} = next_event(state)
      refute_receive {:guardian, _, _, {:written, _, _, _}}, 0
      send(state.pid, {:drain_ack, self(), state.epoch, token})

      assert {:closing, %Error{details: %{native_write_ack: evidence}}} = next_event(state)
      assert evidence == %{id: 1, bytes: count, status: status}
      send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
      assert_frame(state, "T")
      send(state.pid, {state.handle, {:exit_status, 0}})
      assert {:retired, %{cleanup: :retired}} = next_event(state)
      assert_receive {:DOWN, _, :process, _, :normal}
      assert :ok = Lifetime.retired(state.lifetime, state.generation)
    end
  end

  @tag :receive_buffer
  test "a failed terminal acknowledgement cannot become clean retirement after the barrier" do
    state = guardian() |> activate()
    {_ref, _observer, fault} = state.handle
    :atomics.put(fault, 1, 2)
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert {:draining, _origin} = next_event(state)
    assert_frame(state, "T")
    assert {:drain_end, token} = next_event(state)
    send(state.pid, {:drain_ack, self(), state.epoch, token})
    assert {:closing, %Error{}} = next_event(state)
    send(state.pid, {state.handle, {:exit_status, 0}})
    assert {:retired, %{cleanup: :unknown}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
  end

  @tag :receive_buffer
  test "an expired drain cannot retire while its timer message is still queued" do
    state = guardian() |> activate()
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert {:draining, origin} = next_event(state)
    assert_frame(state, "T")
    assert {:drain_end, token} = next_event(state)
    assert :sys.get_state(state.pid).cleanup_at == origin + 750
    send(state.pid, {state.handle, {:exit_status, 0}})

    :sys.replace_state(state.pid, fn current ->
      %{current | cleanup_at: System.monotonic_time(:millisecond) - 1}
    end)

    send(state.pid, {:drain_ack, self(), state.epoch, token})
    assert {:closing, %Error{kind: :timeout}} = next_event(state)
    assert {:retired, %{cleanup: :unknown}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
  end

  @tag :receive_buffer
  test "a closing exit cannot retire after the original cutoff ahead of its timer message" do
    state = guardian() |> activate()
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert {:draining, _origin} = next_event(state)
    assert_frame(state, "T")
    assert {:drain_end, token} = next_event(state)
    send(state.pid, {:drain_ack, self(), state.epoch, token})
    assert {:closing, %Error{kind: :disconnected}} = next_event(state)

    :sys.replace_state(state.pid, fn current ->
      %{current | cleanup_at: System.monotonic_time(:millisecond) - 1}
    end)

    send(state.pid, {state.handle, {:exit_status, 0}})
    assert {:retired, %{cleanup: :unknown}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
  end

  @tag :receive_buffer
  test "bare native exit preserves the queued tail but cannot manufacture retirement proof" do
    state = guardian() |> activate()
    send(state.pid, {:read, self(), state.epoch, state.credit})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "prefix">>}})
    assert {:stdout, "prefix", first} = next_event(state)
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "tail">>}})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:exit_status, 0}})
    assert {:draining, _origin} = next_event(state)
    assert_frame(state, "Q")
    send(state.pid, {:read, self(), state.epoch, first})
    assert {:stdout, "tail", last} = next_event(state)
    send(state.pid, {:read, self(), state.epoch, last})
    assert {:drain_end, token} = next_event(state)
    send(state.pid, {:drain_ack, self(), state.epoch, token})
    assert {:closing, %Error{kind: :disconnected}} = next_event(state)
    assert {:retired, %{cleanup: :unknown}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
  end

  @tag :receive_buffer
  test "explicit closure can abort a queued drain without starting another cleanup clock" do
    state = guardian() |> activate()
    send(state.pid, {:read, self(), state.epoch, state.credit})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "withheld">>}})
    assert {:stdout, "withheld", _credit} = next_event(state)
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?Z, 1>>}})
    assert {:draining, origin} = next_event(state)
    assert_frame(state, "Q")
    send(state.pid, {:close, self(), state.epoch, :test_close})
    assert {:closing, %Error{kind: :test_close}} = next_event(state)
    assert :sys.get_state(state.pid).cleanup_at == origin + 750
    retire(state, :already_closing)
  end

  @tag :receive_buffer
  test "closure after observed native exit uses retained proof instead of waiting for another exit" do
    state = guardian() |> activate()
    send(state.pid, {:read, self(), state.epoch, state.credit})
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?D, 1, "withheld">>}})
    assert {:stdout, "withheld", _credit} = next_event(state)
    assert_frame(state, <<?R, 1, 8192::16>>)
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert {:draining, _origin} = next_event(state)
    assert_frame(state, "T")
    send(state.pid, {state.handle, {:exit_status, 0}})
    send(state.pid, {:close, self(), state.epoch, :test_close})
    assert {:closing, %Error{kind: :test_close}} = next_event(state)
    assert {:retired, %{cleanup: :retired}} = next_event(state)
    assert_receive {:DOWN, _, :process, _, :normal}
    assert :ok = Lifetime.retired(state.lifetime, state.generation)
  end

  test "only the single startup challenge can write before activation" do
    state = guardian()
    assert not Lifetime.allows_write?(state.lifetime, state.generation)
    state = activate(state)
    assert Lifetime.allows_write?(state.lifetime, state.generation)
    retire(state)
  end

  test "the final writer rejects an old consumed lease after its slot is reused" do
    state = guardian() |> activate()
    lease = lease(state, 5)
    send(state.pid, {:write, self(), state.epoch, :not_a_token, lease, 0, 5, "noop\n"})
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :invalid_write}}}
    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0
    retire(state, :already_closing)

    state = guardian() |> activate()
    lease = lease(state, 5)
    operation = make_ref()
    send(state.pid, {:write, self(), state.epoch, operation, lease, 0, 5, "noop\n"})
    assert_frame(state, <<?W, 1::32, "noop\n">>)
    send(state.pid, {state.handle, {:data, <<?A, 1::32, 5::16, 0>>}})
    assert_receive {:guardian, _, _, {:written, ^operation, ^lease, 5}}
    send(state.pid, {:wire_retired, self(), state.epoch, operation, lease})
    assert_receive {:guardian, _, _, {:wire_retired, ^operation, ^lease}}
    assert :ok = Admission.release(state.pool, lease)
    replacement = lease(state, 5)
    assert replacement.generation > lease.generation
    send(state.pid, {:write, self(), state.epoch, operation, lease, 0, 5, "noop\n"})
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :stale_lease}}}
    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0
    retire(state, :already_closing)
  end

  test "a partial line cannot yield its writer to another operation" do
    state = guardian() |> activate()
    lease = lease(state, 6)
    token = make_ref()
    send(state.pid, {:write, self(), state.epoch, token, lease, 0, 6, "abc"})
    assert_frame(state, <<?W, 1::32, "abc">>)
    send(state.pid, {state.handle, {:data, <<?A, 1::32, 3::16, 0>>}})
    assert_receive {:guardian, _, _, {:written, ^token, ^lease, 3}}
    other = lease(state, 5)
    send(state.pid, {:write, self(), state.epoch, make_ref(), other, 0, 5, "noop\n"})
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :partial_line_owned}}}
    refute_receive {:driver_command, _, _, <<?W, _::binary>>}, 0
    retire(state, :already_closing)
  end

  test "a busy port revokes writes and missing proof leaves the lifetime unclean" do
    state = guardian() |> activate()
    {_ref, _observer, fault} = state.handle
    :atomics.put(fault, 1, 1)
    lease = lease(state, 5)
    send(state.pid, {:write, self(), state.epoch, make_ref(), lease, 0, 5, "noop\n"})
    assert_frame(state, <<?W, 1::32, "noop\n">>)
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :port_busy}}}
    assert_frame(state, "Q")
    assert not Lifetime.allows_write?(state.lifetime, state.generation)
    send(state.pid, {state.handle, {:data, <<?F, 4, 0::32>>}})
    assert_receive {:guardian, _, _, {:retired, %{cleanup: :unknown}}}, 850
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
    assert {:error, %Error{kind: :cleanup_unknown}} = Lifetime.begin_epoch(state.lifetime)
  end

  test "fragments finish one line and an abandoned prefix expires under its original deadline" do
    state = guardian() |> activate()
    first = lease(state, 6)
    token = make_ref()

    for {offset, fragment, id} <- [{0, "abc", 1}, {3, "de\n", 2}] do
      send(state.pid, {:write, self(), state.epoch, token, first, offset, 6, fragment})
      assert_frame(state, <<?W, id::32, fragment::binary>>)
      send(state.pid, {state.handle, {:data, <<?A, id::32, 3::16, 0>>}})
      assert_receive {:guardian, _, _, {:written, ^token, ^first, 3}}
    end

    send(state.pid, {:wire_retired, self(), state.epoch, token, first})
    assert_receive {:guardian, _, _, {:wire_retired, ^token, ^first}}
    assert :ok = Admission.release(state.pool, first)
    deadline = Deadline.new(150)
    assert {:ok, lease} = Admission.claim(state.pool, state.epoch, self(), deadline, 6)
    assert :ok = Admission.consume(state.pool, lease, 6)
    send(state.pid, {:write, self(), state.epoch, make_ref(), lease, 0, 6, "abc"})
    assert_frame(state, <<?W, 3::32, "abc">>)
    send(state.pid, {state.handle, {:data, <<?A, 3::32, 3::16, 0>>}})
    assert_receive {:guardian, _, _, {:written, _, ^lease, 3}}
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :timeout}}}, 200
    retire(state, :already_closing)
  end

  test "manager death retires native resources without router demand" do
    manager =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :finish -> :ok
           end
         end}
      )

    state = guardian(manager: manager)
    stop_supervised!(Task)
    assert_receive {:guardian, _, _, {:closing, %Error{kind: :owner_down}}}
    assert_frame(state, "Q")
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert_frame(state, "T")
    send(state.pid, {state.handle, {:exit_status, 0}})
    assert_receive {:guardian, _, _, {:retired, %{cleanup: :retired}}}
    assert_receive {:DOWN, _, :process, _, :normal}
    assert %{phase: :unknown} = Lifetime.status(state.lifetime)
  end

  test "reserved revocation closes starting and saturated ready epochs without actor requests" do
    for active <- [false, true] do
      state = guardian()
      state = if active, do: activate(state), else: state

      if active do
        _first = lease(state, 5)
        _second = lease(state, 5)

        assert {:error, %Error{kind: :resource_limit}} =
                 Admission.claim(state.pool, state.epoch, self(), Deadline.new(500), 5)
      end

      assert :ok = Lifetime.revoke(state.lifetime, state.generation)
      assert_receive {:guardian, _, _, {:closing, %Error{kind: :closure_requested}}}
      retire(state, :already_closing)
    end
  end

  defp guardian(options \\ []) do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    pool = Admission.new(2)
    epoch = make_ref()
    bootstrap = make_ref()

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Guardian,
           manager: Keyword.get(options, :manager, self()),
           router: self(),
           epoch: epoch,
           lifetime: lifetime,
           generation: generation,
           pool: pool,
           bootstrap: bootstrap,
           deadline: Deadline.new(500),
           payload: <<0>>,
           driver: {NativeDriver, observer: self()}},
          id: make_ref()
        )
      )

    monitor = Process.monitor(pid)
    assert_receive {:driver_open, ^pid, handle}

    state = %{
      pid: pid,
      handle: handle,
      epoch: epoch,
      lifetime: lifetime,
      generation: generation,
      pool: pool,
      bootstrap: bootstrap,
      monitor: monitor
    }

    assert_receive {:driver_command, ^pid, ^handle, <<?O, 3, 1, 0::32, 0>>}
    send(pid, {handle, {:data, <<?S, 123::32>>}})
    assert_receive {:guardian, ^epoch, ^pid, {:read_credit, credit}}
    assert_frame(state, <<?R, 2, 8192::16>>)
    Map.put(state, :credit, credit)
  end

  defp activate(state) do
    send(state.pid, {:challenge, self(), state.epoch, state.bootstrap, "ABCD"})
    assert_receive {:driver_command, pid, handle, <<?W, 0::32, command::binary>>}
    assert pid == state.pid and handle == state.handle
    assert byte_size(command) < 8192 and :binary.last(command) == 10
    send(state.pid, {state.handle, {:data, <<?A, 0::32, byte_size(command)::16, 0>>}})
    assert_receive {:guardian, _, _, {:bootstrap_written, token}}
    assert token == state.bootstrap
    send(state.pid, {:activate, self(), state.epoch, state.bootstrap})
    assert_receive {:guardian, _, _, :active}
    state
  end

  defp lease(state, bytes) do
    {:ok, lease} = Admission.claim(state.pool, state.epoch, self(), Deadline.new(500), bytes)
    :ok = Admission.consume(state.pool, lease, bytes)
    lease
  end

  defp assert_frame(state, expected) do
    pid = state.pid
    handle = state.handle
    assert_receive {:driver_command, ^pid, ^handle, ^expected}
  end

  defp next_event(state) do
    pid = state.pid
    epoch = state.epoch
    assert_receive {:guardian, ^epoch, ^pid, event}
    event
  end

  defp retire(state, phase \\ :open) do
    if phase == :open do
      send(state.pid, {:close, self(), state.epoch, :test_close})
      assert_receive {:guardian, _, _, {:closing, %Error{}}}
    end

    assert_frame(state, "Q")
    send(state.pid, {state.handle, {:data, <<?E, 1, 0::32>>}})
    assert_frame(state, "T")
    send(state.pid, {state.handle, {:exit_status, 0}})
    assert_receive {:guardian, _, _, {:retired, %{cleanup: :retired}}}
    assert_receive {:DOWN, _, :process, _, :normal}
    assert :ok = Lifetime.retired(state.lifetime, state.generation)
  end
end
