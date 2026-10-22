defmodule LibTmux.ControlInboxTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Inbox

  test "a closed completed receipt is reusable before the next owner sweep" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.close(inbox, ticket)

    assert {:error, %Error{kind: :resource_limit}} =
             Inbox.publish(inbox, make_ref(), Deadline.new(100, now: 0), {:reconnect, nil},
               now: 1
             )

    assert :ok = Inbox.finish(inbox, ticket, :ok, now: 2)
    replacement = publish(inbox)
    assert replacement.generation == ticket.generation + 1
    assert {:error, %Error{kind: :stale_ticket}} = Inbox.close(inbox, ticket)
    assert :pending = Inbox.result(inbox, replacement)
    assert :ok = Inbox.close(inbox, replacement)
  end

  test "retained results copy binary leaves without losing reference identity" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    parent = :binary.copy("x", 1_048_576)
    slice = binary_part(parent, 32_768, 4096)
    assert :binary.referenced_byte_size(slice) == byte_size(parent)
    resource = inbox.wake
    :atomics.put(resource, 1, 7)

    assert :ok =
             Inbox.finish(inbox, ticket, {:ok, %{values: [slice, {slice}], resource: resource}},
               now: 2
             )

    assert {:ok, {:ok, %{values: [first, {second}], resource: ^resource}}} =
             Inbox.result(inbox, ticket)

    assert first == slice and second == slice
    assert :binary.referenced_byte_size(first) == byte_size(first)
    assert :binary.referenced_byte_size(second) == byte_size(second)
    assert :atomics.get(resource, 1) == 7
    assert :ok = Inbox.close(inbox, ticket)
  end

  test "retained results reject executable and overly nested values" do
    inbox = Inbox.new(1, kinds: [:reconnect])

    for value <- [
          fn -> :not_data end,
          :atomics.new(1024, []),
          Enum.reduce(1..65, 0, fn _, value -> {value} end)
        ] do
      ticket = publish(inbox)
      assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
      assert :ok = Inbox.finish(inbox, ticket, {:ok, value}, now: 2)

      assert {:ok, {:error, %Error{kind: kind}}} = Inbox.result(inbox, ticket)
      assert kind in [:invalid_outcome, :resource_limit]
      assert :ok = Inbox.close(inbox, ticket)
      assert {:ok, 1} = Inbox.reap(inbox)
    end
  end

  test "a separately bounded envelope retains every admitted reply byte and binary map key" do
    inbox = Inbox.new(1, kinds: [:reconnect], max_outcome_bytes: 131_072)
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    parent = :binary.copy("k", 1_048_576)
    key = binary_part(parent, 100, 4096)

    outcome =
      {:ok,
       %{
         key => true,
         outcome: :completed,
         certainty: :acknowledged,
         evidence: :command_reply,
         guard: {1, 4, 1},
         lines: List.duplicate(:binary.copy("x", 64), 1024)
       }}

    assert :erlang.external_size(outcome) > 65_536
    assert :ok = Inbox.finish(inbox, ticket, outcome, now: 2)
    assert {:ok, ^outcome} = Inbox.result(inbox, ticket)
    assert {:ok, {:ok, copied}} = Inbox.result(inbox, ticket)
    stored_key = Enum.find(Map.keys(copied), &is_binary/1)
    assert :binary.referenced_byte_size(stored_key) == byte_size(stored_key)
    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 1} = Inbox.reap(inbox)

    for oversized <- [:binary.copy("x", 131_073), Enum.to_list(1..8192)] do
      ticket = publish(inbox)
      assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
      assert :ok = Inbox.finish(inbox, ticket, oversized, now: 2)
      assert {:ok, {:error, %Error{kind: :resource_limit}}} = Inbox.result(inbox, ticket)
      assert :ok = Inbox.close(inbox, ticket)
      assert {:ok, 1} = Inbox.reap(inbox)
    end
  end

  test "the minimum outcome allowance covers its fixed error envelope" do
    assert_raise ArgumentError, fn ->
      Inbox.new(1, kinds: [:reconnect], max_outcome_bytes: 1)
    end

    inbox = Inbox.new(1, kinds: [:reconnect], max_outcome_bytes: 1024)
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)
    assert :ok = Inbox.finish(inbox, ticket, :binary.copy("x", 4096), now: 2)
    assert {:ok, {:error, %Error{kind: :resource_limit}} = outcome} = Inbox.result(inbox, ticket)
    assert :erlang.external_size(outcome) <= inbox.max_outcome_bytes
    assert :ok = Inbox.close(inbox, ticket)
    assert {:ok, 1} = Inbox.reap(inbox)
    ticket = publish(inbox)
    assert {:ok, [{^ticket, _}]} = Inbox.take(inbox, now: 1)

    assert :ok =
             Inbox.finish(
               inbox,
               ticket,
               {:ok,
                %{outcome: :completed, certainty: :acknowledged, lines: [:binary.copy("x", 4096)]}},
               now: 2
             )

    assert {:ok, {:error, %Error{kind: :resource_limit, certainty: :acknowledged}}} =
             Inbox.result(inbox, ticket)

    assert :ok = Inbox.close(inbox, ticket)
  end

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
