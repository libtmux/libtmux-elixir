defmodule LibTmux.ControlWaitersTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Admission, Inbox, Records, Waiters}
  alias LibTmux.Operation.Lifecycle

  test "a paused recipient keeps its exact result after record forget and slot reuse" do
    {records, lease, record} = operation()
    waiters = Waiters.new(records, 1)
    observer = self()

    receiver =
      start_supervised!(
        {Task,
         fn ->
           ticket = await_ticket(waiters, lease)
           send(observer, {:ticket, ticket})

           receive do
             :resume ->
               send(observer, {:result, Inbox.result(waiters.inbox, ticket)})
               Inbox.close(waiters.inbox, ticket)
           end
         end}
      )

    assert_receive {:ticket, ticket}
    waiters = Waiters.turn(waiters, now: 1)
    assert map_size(waiters.active) == 1
    terminal = complete(record)
    :ets.insert(records.table, {lease.slot, terminal})
    {waiters, :ok} = Waiters.forget_current(waiters, lease, now: 2)
    assert waiters.active == %{}
    replacement = claim(records.pool, lease.epoch)
    assert replacement.slot == lease.slot and replacement.generation > lease.generation
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(records, lease)
    waiters = Waiters.turn(waiters, now: 200)

    assert {:error, %Error{kind: :resource_limit}} =
             Inbox.publish(
               waiters.inbox,
               lease.epoch,
               Deadline.new(100, now: 200),
               {:await, replacement},
               now: 200
             )

    monitor = Process.monitor(receiver)
    send(receiver, :resume)
    result = terminal.life.result
    assert_receive {:result, {:ok, {:ok, ^result}}}
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}
    waiters = Waiters.turn(waiters, now: 201)

    assert :ets.lookup(waiters.inbox.table, ticket.slot) == [
             {ticket.slot, %{generation: ticket.generation, state: :free}}
           ]
  end

  test "canonical replies settle before wire retirement and waiter expiry does not stop the operation" do
    {records, lease, record} = operation()
    waiters = Waiters.new(records, 2)
    early = await_ticket(waiters, lease)
    expired = await_ticket(waiters, lease, 2)
    waiters = Waiters.turn(waiters, now: 1)

    {:ok, life, _} =
      Lifecycle.step(
        record.life,
        {:owner, lease.epoch, record.token, {:reply, :ok, {1, 4, 1}, ["v1:early"]}},
        now: 2
      )

    :ets.insert(records.table, {lease.slot, %{record | life: life}})
    waiters = Waiters.turn(waiters, now: 3)
    assert {:ok, {:ok, result}} = Inbox.result(waiters.inbox, early)
    assert result.lines == ["v1:early"]
    assert {:ok, {:error, %Error{kind: :timeout}}} = Inbox.result(waiters.inbox, expired)
    assert {:ok, %{life: %{wire: :writing, result: ^result}}} = Records.fetch(records, lease)
    {waiters, {:error, %Error{kind: :wire_active}}} = Waiters.forget(waiters, lease, now: 3)
    assert waiters.active == %{}
    assert :ok = Inbox.close(waiters.inbox, early)
    assert :ok = Inbox.close(waiters.inbox, expired)
  end

  test "closed waiter aliases release only waiter capacity and failed delivery prevents forget" do
    {records, lease, record} = operation()
    waiters = Waiters.new(records, 1)
    ticket = await_ticket(waiters, lease)
    waiters = Waiters.turn(waiters, now: 1)
    assert :ok = Inbox.close(waiters.inbox, ticket)
    waiters = Waiters.turn(waiters, now: 2)
    assert waiters.active == %{}
    assert {:ok, %{life: %{result: nil, wire: :writing}}} = Records.fetch(records, lease)
    waiters = Waiters.turn(waiters, now: 3)
    _ticket = await_ticket(waiters, lease)
    waiters = Waiters.turn(waiters, now: 4)
    terminal = complete(record)
    :ets.insert(records.table, {lease.slot, terminal})
    :ets.delete(waiters.inbox.table)

    {_waiters, {:error, %Error{kind: :connection_lost}}} =
      Waiters.forget_current(waiters, lease, now: 5)

    assert {:ok, ^terminal} = Records.fetch(records, lease)
  end

  test "forget after an owner pass respects later cancellation, expiry and storage loss" do
    for mode <- [:closed, :expired, :lost] do
      {records, lease, record} = operation()
      waiters = Waiters.new(records, 1)
      ticket = await_ticket(waiters, lease, 3)
      waiters = Waiters.turn(waiters, now: 1)
      terminal = complete(record)
      :ets.insert(records.table, {lease.slot, terminal})

      case mode do
        :lost ->
          :ok = Inbox.close(waiters.inbox, ticket)
          waiters = Waiters.turn(waiters, now: 2)
          assert waiters.active == %{}
          :ets.delete(waiters.inbox.table)

          {_waiters, {:error, %Error{kind: :connection_lost}}} =
            Waiters.forget_current(waiters, lease, now: 2)

          assert {:ok, ^terminal} = Records.fetch(records, lease)

        _ ->
          if mode == :closed, do: Inbox.close(waiters.inbox, ticket)

          {waiters, :ok} =
            Waiters.forget_current(waiters, lease, now: if(mode == :expired, do: 4, else: 2))

          assert waiters.active == %{}
          expected = if mode == :closed, do: :cancelled, else: :timeout

          assert {:ok, {:error, %Error{kind: ^expected, certainty: :unknown}}} =
                   Inbox.result(waiters.inbox, ticket)

          assert :ok = Inbox.close(waiters.inbox, ticket)
      end
    end
  end

  test "expiry or receipt closure before acceptance does not claim the target was unwritten" do
    {records, lease, record} = operation()
    :ets.insert(records.table, {lease.slot, complete(record)})

    for mode <- [:expired, :closed] do
      waiters = Waiters.new(records, 1)
      ticket = await_ticket(waiters, lease, 2)
      if mode == :closed, do: Inbox.close(waiters.inbox, ticket)
      waiters = Waiters.turn(waiters, now: if(mode == :expired, do: 3, else: 1))

      assert {:ok, {:error, %Error{kind: kind, certainty: :unknown}}} =
               Inbox.result(waiters.inbox, ticket)

      assert kind == if(mode == :expired, do: :timeout, else: :cancelled)
      assert waiters.active == %{}

      assert {:ok, %{life: %{result: %{certainty: :acknowledged}}}} =
               Records.fetch(records, lease)

      assert :ok = Inbox.close(waiters.inbox, ticket)
    end
  end

  defp operation do
    pool = Admission.new(1)
    records = Records.new(pool)
    epoch = make_ref()
    lease = claim(pool, epoch)
    assert :ok = Admission.consume(pool, lease, 5)
    token = make_ref()
    life = Lifecycle.new(epoch, token, %Deadline{expires_at: lease.expires_at}, 5)
    {:ok, life, _} = Lifecycle.step(life, {:owner, epoch, token, :dispatch}, now: 1)
    record = %{lease: lease, token: token, life: life, reply: nil}
    :ets.insert(records.table, {lease.slot, record})
    {records, lease, record}
  end

  defp claim(pool, epoch) do
    {:ok, lease} = Admission.claim(pool, epoch, self(), Deadline.new(500, now: 0), 5, now: 0)
    lease
  end

  defp complete(record) do
    %{lease: lease, token: token, life: life} = record
    {:ok, life, _} = Lifecycle.step(life, {:owner, lease.epoch, token, {:written, 5}}, now: 1)

    {:ok, life, _} =
      Lifecycle.step(
        life,
        {:owner, lease.epoch, token, {:reply, :ok, {1, 4, 1}, ["v1:retained"]}},
        now: 1
      )

    {:ok, life, _} = Lifecycle.step(life, {:owner, lease.epoch, token, :retire}, now: 1)
    %{record | life: life}
  end

  defp await_ticket(waiters, lease, timeout \\ 100) do
    {:ok, ticket} =
      Inbox.publish(waiters.inbox, lease.epoch, Deadline.new(timeout, now: 0), {:await, lease},
        now: 0
      )

    ticket
  end
end
