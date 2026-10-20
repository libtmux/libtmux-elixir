defmodule LibTmux.ControlInboxTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Inbox

  test "a paused recipient retains capacity until it closes its alias and acknowledges receipt" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    parent = self()
    epoch = make_ref()

    receiver =
      start_supervised!(
        {Task,
         fn ->
           {:ok, ticket} =
             Inbox.publish(
               inbox,
               epoch,
               Deadline.new(100, now: 0),
               {:reconnect, nil},
               now: 0
             )

           send(parent, {:ticket, ticket})

           receive do
             :resume ->
               send(parent, {:result, Inbox.result(inbox, ticket)})
               :ok = Inbox.close(inbox, ticket)
           end
         end}
      )

    assert_receive {:ticket, ticket}
    assert {:ok, [{^ticket, {:reconnect, nil}}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.finish(inbox, ticket, {:ok, :connected}, now: 2)
    assert {:ok, 0} = Inbox.reap(inbox)

    assert {:error, %Error{kind: :resource_limit}} =
             Inbox.publish(
               inbox,
               epoch,
               Deadline.new(100, now: 150),
               {:reconnect, nil},
               now: 150
             )

    monitor = Process.monitor(receiver)
    send(receiver, :resume)
    assert_receive {:result, {:ok, {:ok, :connected}}}
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}
    assert {:ok, 1} = Inbox.reap(inbox)
  end

  test "closing a waiter receipt does not recycle its unfinished owner work" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _request}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 0} = Inbox.reap(inbox)
    assert :ok = Inbox.finish(inbox, ticket, {:ok, :effect_completed}, now: 2)
    refute_receive {_, :ready}, 0
    assert {:ok, 1} = Inbox.reap(inbox)
    replacement = publish(inbox)
    assert replacement.generation > ticket.generation
    assert {:error, %Error{kind: :stale_ticket}} = Inbox.result(inbox, ticket)
    assert :ok = Inbox.close(inbox, replacement)
    assert {:ok, []} = Inbox.take(inbox, now: 1)
    assert {:ok, 1} = Inbox.reap(inbox)
  end

  test "a frozen wake hint survives slot reuse without allowing another delayed hint" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    assert {:ok, hint} = Inbox.reserve_wake(inbox)

    for _ <- 1..8 do
      ticket = publish(inbox)
      assert :pending = Inbox.reserve_wake(inbox)
      assert {:ok, [{^ticket, _request}]} = Inbox.take(inbox, now: 1)
      assert :ok = Inbox.finish(inbox, ticket, {:ok, :done}, now: 2)
      assert :ok = Inbox.close(inbox, ticket)
      assert {:ok, 1} = Inbox.reap(inbox)
    end

    assert :ok = Inbox.consume_wake(inbox, hint)
    assert {:ok, next} = Inbox.reserve_wake(inbox)
    assert {:error, %Error{kind: :stale_hint}} = Inbox.consume_wake(inbox, hint)
    assert :pending = Inbox.reserve_wake(inbox)
    assert :ok = Inbox.consume_wake(inbox, next)
  end

  test "expired requests and forged ticket metadata cannot cause owner work or release another row" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    ticket = publish(inbox)

    for invalid <- [
          %{ticket | generation: :"$1"},
          %{ticket | generation: ticket.generation * 1.0}
        ] do
      assert {:error, %Error{kind: :stale_ticket}} = Inbox.close(inbox, invalid)
    end

    assert {:ok, []} = Inbox.take(inbox, now: 100)

    assert {:ok, {:error, %Error{kind: :timeout, certainty: :no_write}}} =
             Inbox.result(inbox, ticket)

    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 1} = Inbox.reap(inbox)
  end

  test "concurrent metadata publishers cannot exceed fixed capacity" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    parent = self()

    for index <- 1..32 do
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Inbox.publish(
                 inbox,
                 make_ref(),
                 Deadline.new(100, now: 0),
                 {:reconnect, nil},
                 now: 0
               )

             send(parent, {:publication, result})
           end},
          id: {:publisher, index}
        )
      )
    end

    results =
      for _ <- 1..32 do
        assert_receive {:publication, result}
        result
      end

    assert [{:ok, _ticket}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, %Error{kind: :resource_limit}}, &1)) == 31
    assert :ets.info(inbox.table, :size) == 2
  end

  test "owner death loses the ticket while the caller still retires its reply alias" do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           send(parent, {:inbox, Inbox.new(1, kinds: [:reconnect])})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {:inbox, inbox}
    ticket = publish(inbox)
    monitor = Process.monitor(owner)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert {:error, %Error{kind: :connection_lost}} = Inbox.result(inbox, ticket)
    assert {:error, %Error{kind: :connection_lost}} = Inbox.close(inbox, ticket)
    send(ticket.reply, {ticket.token, :ready})
    refute_receive {_, :ready}, 0
  end

  test "changing an inbox struct cannot acquire owner authority or substitute its receipt word" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         forged = %{inbox | owner: self()}
         send(parent, {:forged_owner, Inbox.take(forged, now: 1)})
       end}
    )

    assert_receive {:forged_owner, {:error, %Error{kind: :wrong_inbox}}}
    ticket = publish(inbox)
    other = Inbox.new(1, kinds: [:reconnect])

    assert {:error, %Error{kind: :wrong_inbox}} =
             Inbox.close(%{inbox | receipts: other.receipts}, ticket)

    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.finish(inbox, ticket, {:ok, :done}, now: 2)
    assert {:ok, 0} = Inbox.reap(inbox)
    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 1} = Inbox.reap(inbox)
  end

  test "only the original caller and captured alias can read or acknowledge a receipt" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    ticket = publish(inbox)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:foreign_read, Inbox.result(inbox, ticket)})
         send(parent, {:foreign_close, Inbox.close(inbox, ticket)})
       end}
    )

    assert_receive {:foreign_read, {:error, %Error{kind: :wrong_receiver}}}
    assert_receive {:foreign_close, {:error, %Error{kind: :wrong_receiver}}}
    alias_ref = :erlang.alias()

    assert {:error, %Error{kind: :stale_ticket}} =
             Inbox.close(inbox, %{ticket | reply: alias_ref})

    assert :erlang.unalias(alias_ref)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.finish(inbox, ticket, {:ok, :done}, now: 2)
    assert_receive {token, :ready}
    assert token == ticket.token
    assert :ok = Inbox.close(inbox, ticket)
    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 1} = Inbox.reap(inbox)
    replacement = publish(inbox)
    assert :ok = Inbox.close(inbox, replacement)
    assert {:error, %Error{kind: :stale_ticket}} = Inbox.close(inbox, ticket)
    assert {:ok, []} = Inbox.take(inbox, now: 1)
    assert {:ok, 1} = Inbox.reap(inbox)
  end

  defp publish(inbox) do
    {:ok, ticket} =
      Inbox.publish(
        inbox,
        make_ref(),
        Deadline.new(100, now: 0),
        {:reconnect, nil},
        now: 0
      )

    ticket
  end
end
