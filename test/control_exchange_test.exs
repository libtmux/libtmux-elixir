defmodule LibTmux.ControlExchangeTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Exchange, Inbox}

  test "closing a failed exchange wakes the owner without a sweep" do
    inbox = Inbox.new(1, kinds: [:reconnect])
    owner = self()

    caller =
      start_supervised!(
        {Task,
         fn ->
           result = Exchange.call(inbox, make_ref(), Deadline.new(500), {:reconnect, nil})
           send(owner, {:result, result})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {Inbox, :wake, table, generation}
    assert :ok = Inbox.consume_wake(inbox, {self(), table, generation})
    assert {:ok, [{ticket, _request}]} = Inbox.take(inbox)
    send(ticket.reply, {ticket.token, :ready})
    assert_receive {:result, {:error, %Error{kind: :invalid_reply}}}
    assert_receive {Inbox, :wake, ^table, next}, 0
    assert next > generation
    assert :ok = Inbox.consume_wake(inbox, {self(), table, next})
    assert {:ok, true} = Inbox.closed?(inbox, ticket)
    assert :ok = Inbox.finish(inbox, ticket, :ok)
    assert {:ok, 1} = Inbox.reap(inbox)
    send(caller, :finish)
  end
end
