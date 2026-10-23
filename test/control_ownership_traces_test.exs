defmodule LibTmux.ControlOwnershipTracesTest do
  use ExUnit.Case, async: true
  alias LibTmux.Deadline
  alias LibTmux.Control.{Admission, Inbox, Records, Waiters}
  alias LibTmux.Operation.Lifecycle

  test "generated wire schedules preserve one settlement, final evidence and retirement" do
    interruptions = [
      :cancel_waiter,
      :cancel_operation,
      :expire,
      {:epoch_closed, :epoch},
      {:owner, :stale, :token, {:reply, :ok, {1, 2, 1}, []}},
      {:owner, :epoch, :stale, {:written, 1}}
    ]

    for status <- [:ok, :error],
        order <-
          permutations([
            :dispatch,
            {:written, 2},
            {:written, 3},
            {:reply, status, {1, 2, 1}, ["x"]},
            :retire
          ]),
        interruption <- interruptions,
        position <- 0..5 do
      events = Enum.map(order, &{:owner, :epoch, :token, &1})
      events = List.insert_at(events, position, interruption)

      events =
        events ++
          [
            {:owner, :epoch, :token, {:reply, :error, {2, 3, 1}, ["late"]}},
            {:epoch_closed, :epoch},
            {:owner, :epoch, :token, :dispatch}
          ]

      life = Lifecycle.new(:epoch, :token, Deadline.new(100, now: 0), 5)

      {life, settlements, dispatches, _clock} =
        Enum.reduce(events, {life, 0, 0, 0}, fn event, {previous, settled, dispatched, clock} ->
          clock = if event == :expire, do: 100, else: clock + 1
          transition = Lifecycle.step(previous, event, now: clock)

          case event do
            {:owner, :stale, :token, _} ->
              assert {:error, %{kind: :stale_epoch}} = transition

            {:owner, :epoch, :stale, _} ->
              assert {:error, %{kind: :stale_operation}} = transition

            _ ->
              :ok
          end

          case transition do
            {:ok, next, actions} ->
              settled = settled + Enum.count(actions, &match?({:settle, _}, &1))

              dispatched =
                dispatched +
                  if(previous.wire == :unsent and next.wire == :writing, do: 1, else: 0)

              assert settled <= 1 and dispatched <= 1
              assert next.written >= previous.written and next.written <= 5
              if previous.result, do: assert(next.result == previous.result)
              if previous.wire == :retired, do: assert(next.wire == :retired)

              if next.wire == :retired do
                assert next.result != nil

                assert previous.wire == :retired or event == {:epoch_closed, :epoch} or
                         next.result.outcome == :skipped or
                         (next.written == 5 and next.result.certainty == :acknowledged)
              end

              if next.result && next.result.outcome == :skipped, do: assert(dispatched == 0)
              if clock >= 100, do: assert(next.written == previous.written)
              {next, settled, dispatched, clock}

            {:error, %{kind: kind}} ->
              assert kind in [:invalid_transition, :stale_epoch, :stale_operation]
              {previous, settled, dispatched, clock}
          end
        end)

      assert life.wire == :retired and life.result != nil
      assert settlements == 1 and dispatches <= 1
    end
  end

  test "generated receipt and publisher schedules never reclaim active wire or grow storage" do
    for order <- permutations([:reply, :write, :retire]),
        interruption <- [:forget, :expire_waiter, :close_receipt, :caller_death],
        position <- 0..3,
        mode <- [:retained, :managed] do
      schedule = List.insert_at(order, position, interruption)
      trace_ownership(schedule, mode)
    end
  end

  defp trace_ownership(schedule, mode) do
    pool = Admission.new(1)
    records = Records.new(pool)
    waiters = Waiters.new(records, 1)
    epoch = make_ref()
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, lease} =
          Admission.claim(pool, epoch, owner, Deadline.new(500, now: 0), 5, now: 0, mode: mode)

        {:ok, ticket} =
          Inbox.publish(waiters.inbox, epoch, Deadline.new(10, now: 0), {:collect, lease}, now: 0)

        send(owner, {epoch, lease, ticket})
        recipient(owner, epoch, waiters.inbox, ticket)
      end)

    assert_receive {^epoch, lease, ticket}

    try do
      assert :ok = Admission.consume(pool, lease, 5)
      token = make_ref()
      life = Lifecycle.new(epoch, token, Deadline.new(500, now: 0), 5)
      {:ok, life, []} = Lifecycle.step(life, {:owner, epoch, token, :dispatch}, now: 0)
      record = %{lease: lease, token: token, life: life, reply: nil}
      :ets.insert(records.table, {lease.slot, record})
      initial = %{record: record, waiters: Waiters.turn(waiters, now: 0), clock: 0, result: nil}

      final =
        Enum.reduce(schedule ++ [:close_epoch, :forget], initial, fn event, state ->
          clock = if event == :expire_waiter, do: 20, else: state.clock

          state =
            case event do
              :close_receipt ->
                send(caller, :close)
                assert_receive {^epoch, :closed}
                state

              :caller_death ->
                Process.exit(caller, :kill)
                assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
                state

              :forget ->
                {next, outcome} = Waiters.forget_current(state.waiters, lease, now: clock)

                if not Lifecycle.wire_retired?(state.record.life),
                  do: assert(match?({:error, %{kind: :wire_active}}, outcome))

                %{state | waiters: next}

              :expire_waiter ->
                state

              event ->
                wire_event =
                  case event do
                    :reply -> {:owner, epoch, token, {:reply, :ok, {1, 2, 1}, ["x"]}}
                    :write -> {:owner, epoch, token, {:written, 5}}
                    :retire -> {:owner, epoch, token, :retire}
                    :close_epoch -> {:epoch_closed, epoch}
                  end

                case Records.fetch(records, lease) do
                  {:ok, current} ->
                    case Lifecycle.step(current.life, wire_event, now: clock) do
                      {:ok, next, _actions} ->
                        updated = %{current | life: next}
                        :ets.insert(records.table, {lease.slot, updated})
                        %{state | record: updated}

                      {:error, %{kind: :invalid_transition}} ->
                        state
                    end

                  {:error, %{kind: :stale_operation}} ->
                    state
                end
            end

          state = %{state | waiters: Waiters.turn(state.waiters, now: clock), clock: clock}
          assert state.waiters.fault == nil
          assert map_size(state.waiters.active) <= 1 and map_size(state.waiters.publishers) <= 1
          assert :ets.info(pool.table, :size) == 2
          assert :ets.info(records.table, :size) == 2
          assert :ets.info(waiters.inbox.table, :size) == 2
          if state.result, do: assert(state.record.life.result == state.result)

          unless Lifecycle.wire_retired?(state.record.life) do
            assert {:ok, _record} = Records.fetch(records, lease)
            assert {:error, %{kind: :wire_active}} = Records.forget(records, lease)

            assert {:error, %{kind: :resource_limit}} =
                     Admission.claim(pool, epoch, self(), Deadline.new(500, now: 0), 5,
                       now: clock
                     )
          end

          %{state | result: state.record.life.result}
        end)

      assert {:ok, []} = Admission.entries(pool)
      assert final.waiters.active == %{} and final.waiters.publishers == %{}
      assert {:error, %{kind: :stale_operation}} = Records.fetch(records, lease)

      if Process.alive?(caller) do
        send(caller, :finish)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
      end

      final = Waiters.turn(final.waiters, now: 21)
      assert [{_, %{state: :free}}] = :ets.lookup(final.inbox.table, ticket.slot)
    after
      Process.exit(caller, :kill)
      Process.demonitor(monitor, [:flush])
      Enum.each([pool.table, records.table, waiters.inbox.table], &:ets.delete/1)
    end
  end

  defp recipient(owner, epoch, inbox, ticket) do
    receive do
      :close ->
        :ok = Inbox.close(inbox, ticket)
        send(owner, {epoch, :closed})
        recipient(owner, epoch, inbox, ticket)

      :finish ->
        :ok
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(items),
    do: for(item <- items, rest <- permutations(List.delete(items, item)), do: [item | rest])
end
