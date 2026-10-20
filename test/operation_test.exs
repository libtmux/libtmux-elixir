defmodule LibTmux.OperationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error, Operation}
  alias LibTmux.Control.{Admission, Births, Inbox, Lifetime, Records, Waiters}
  alias LibTmux.Operation.Lifecycle
  @moduletag :capture_log

  test "retained reads distinguish a canonical reply from wire retirement and lost context" do
    {operation, endpoint, record, _waiters} = operation()
    assert :pending = Operation.result(operation)
    assert {:ok, %{wire: :writing, result: nil}} = Operation.status(operation)
    terminal = complete(record, false)
    :ets.insert(endpoint.records.table, {record.lease.slot, terminal})
    assert {:ok, result} = Operation.result(operation)
    assert result.certainty == :acknowledged
    assert {:ok, %{wire: :writing, result: ^result}} = Operation.status(operation)
    :ets.delete(endpoint.records.table)

    assert {:error, %Error{kind: :connection_lost, certainty: :unknown}} =
             Operation.result(operation)

    assert_raise Error, fn -> Operation.result!(operation) end
  end

  test "await overload cannot describe an acknowledged target as unwritten" do
    {operation, endpoint, record, waiters} = operation()
    terminal = complete(record)
    :ets.insert(endpoint.records.table, {record.lease.slot, terminal})

    {:ok, held} =
      Inbox.publish(waiters.inbox, record.lease.epoch, Deadline.new(500), {:await, record.lease})

    assert {:error, %Error{kind: :resource_limit, phase: :wait, certainty: :unknown}} =
             Operation.await(operation, timeout: 100)

    assert {:ok, result} = Operation.result(operation)
    assert result == terminal.life.result
    assert :ok = Inbox.close(waiters.inbox, held)
  end

  test "an expired await releases only its receipt and owner monitor" do
    {operation, endpoint, record, waiters} = operation()
    observer = self()

    start_supervised!(
      {Task,
       fn ->
         send(
           observer,
           {:await_result, Operation.await(operation, timeout: 25),
            Process.info(self(), :monitors)}
         )
       end}
    )

    table = waiters.inbox.table
    assert_receive {Inbox, :wake, ^table, _generation}, 100
    waiters = Waiters.turn(waiters)
    assert map_size(waiters.active) == 1

    assert_receive {:await_result, {:error, %Error{kind: :timeout, certainty: :unknown}},
                    {:monitors, []}},
                   100

    waiters = Waiters.turn(waiters)
    assert waiters.active == %{}
    assert {:ok, ^record} = Records.fetch(endpoint.records, record.lease)
    assert Lifetime.allows_write?(endpoint.lifetime, endpoint.generation)
  end

  test "accepted await copies survive record release before a suspended caller resumes" do
    {operation, endpoint, record, waiters} = operation()
    observer = self()

    caller =
      start_supervised!(
        {Task,
         fn -> send(observer, {:await_result, Operation.await(operation, timeout: 500)}) end}
      )

    table = waiters.inbox.table
    assert_receive {Inbox, :wake, ^table, _generation}, 100
    true = :erlang.suspend_process(caller)

    try do
      waiters = Waiters.turn(waiters)
      terminal = complete(record)
      :ets.insert(endpoint.records.table, {record.lease.slot, terminal})
      {_waiters, :ok} = Waiters.forget(waiters, record.lease)
      assert {:error, %Error{kind: :stale_operation}} = Operation.result(operation)

      {:ok, replacement} =
        Admission.claim(endpoint.pool, endpoint.epoch, self(), Deadline.new(500), 5)

      assert replacement.generation > record.lease.generation
    after
      :erlang.resume_process(caller)
    end

    assert_receive {:await_result, {:ok, %{certainty: :acknowledged, lines: ["v1:retained"]}}},
                   100
  end

  test "await owner death returns promptly and removes its caller monitor" do
    observer = self()

    owner =
      start_supervised!(%{
        id: :owner,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               {operation, _endpoint, _record, waiters} = operation()
               send(observer, {:operation, operation})

               receive do
                 {Inbox, :wake, _table, _generation} ->
                   Waiters.turn(waiters)
                   send(observer, :waiter_accepted)
               end

               receive do
                 :finish -> :ok
               end
             end
           ]}
      })

    assert_receive {:operation, operation}

    start_supervised!(%{
      id: :caller,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             send(
               observer,
               {:await_result, Operation.await(operation, timeout: 500),
                Process.info(self(), :monitors)}
             )
           end
         ]}
    })

    assert_receive :waiter_accepted, 100
    send(owner, :finish)

    assert_receive {:await_result, {:error, %Error{kind: :connection_lost, certainty: :unknown}},
                    {:monitors, []}},
                   100
  end

  test "accepted forget remains owned after its caller times out" do
    {operation, endpoint, record, waiters} = operation()
    :ets.insert(endpoint.records.table, {record.lease.slot, complete(record)})
    observer = self()

    start_supervised!(
      {Task, fn -> send(observer, {:forget_result, Operation.forget(operation, timeout: 25)}) end}
    )

    table = endpoint.inbox.table
    assert_receive {Inbox, :wake, ^table, _generation}, 100
    {:ok, [{ticket, {:forget, lease}}]} = Inbox.take(endpoint.inbox)
    assert_receive {:forget_result, {:error, %Error{kind: :timeout, certainty: :unknown}}}, 100
    {_waiters, :ok} = Waiters.forget(waiters, lease)
    assert :ok = Inbox.finish(endpoint.inbox, ticket, :ok)
    assert {:error, %Error{kind: :stale_operation}} = Operation.result(operation)
  end

  test "reserved stop validates Births and cannot close a foreign or replacement epoch" do
    {operation, endpoint, record, waiters} = operation()
    foreign = Lifetime.new()
    {:ok, 1} = Lifetime.begin_epoch(foreign)
    assert :ok = Lifetime.ready(foreign, 1)
    forged = %{operation | births: %{endpoint.births | lifetime: foreign}}
    assert {:error, %Error{certainty: :unknown}} = Operation.stop(forged)
    assert Lifetime.allows_write?(foreign, 1)

    {:ok, held} =
      Inbox.publish(waiters.inbox, endpoint.epoch, Deadline.new(500), {:await, record.lease})

    {:ok, metadata} =
      Inbox.publish(endpoint.inbox, endpoint.epoch, Deadline.new(500), {:forget, record.lease})

    assert :ok = Operation.stop(operation)
    assert Lifetime.status(endpoint.lifetime).phase == :closing
    assert :ok = Lifetime.retired(endpoint.lifetime, 1)
    {:ok, 2} = Lifetime.begin_epoch(endpoint.lifetime)
    assert :ok = Lifetime.ready(endpoint.lifetime, 2)
    assert {:error, %Error{kind: :stale_epoch, certainty: :unknown}} = Operation.stop(operation)
    assert Lifetime.allows_write?(endpoint.lifetime, 2)
    :ets.insert(endpoint.records.table, {record.lease.slot, complete(record)})
    :ets.delete(endpoint.births.table)
    assert :ok = Operation.stop(operation)
    assert Lifetime.allows_write?(endpoint.lifetime, 2)
    assert :ok = Inbox.close(waiters.inbox, held)
    assert :ok = Inbox.close(endpoint.inbox, metadata)
  end

  defp operation do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    epoch = make_ref()
    births = Births.new(lifetime, generation, epoch, Deadline.new(500))
    assert :ok = Births.register(births, :router)
    assert :ok = Lifetime.ready(lifetime, generation)
    pool = Admission.new(1)
    records = Records.new(pool)
    inbox = Inbox.new(1, kinds: [:forget, :reconnect])
    waiters = Waiters.new(records, 1)

    endpoint = %{
      manager: self(),
      router: self(),
      pool: pool,
      records: records,
      inbox: inbox,
      waiter_inbox: waiters.inbox,
      births: births,
      lifetime: lifetime,
      generation: generation,
      epoch: epoch
    }

    {:ok, lease} = Admission.claim(pool, epoch, self(), Deadline.new(500), 5)
    assert :ok = Admission.consume(pool, lease, 5)
    token = make_ref()
    life = Lifecycle.new(epoch, token, %Deadline{expires_at: lease.expires_at}, 5)
    {:ok, life, _} = Lifecycle.step(life, {:owner, epoch, token, :dispatch})
    record = %{lease: lease, token: token, life: life, reply: nil}
    :ets.insert(records.table, {lease.slot, record})
    {Operation.new(endpoint, lease), endpoint, record, waiters}
  end

  defp complete(record, retire \\ true) do
    %{lease: lease, token: token, life: life} = record

    {:ok, life, _} =
      Lifecycle.step(
        life,
        {:owner, lease.epoch, token, {:reply, :ok, {1, 4, 1}, ["v1:retained"]}}
      )

    if retire do
      {:ok, life, _} = Lifecycle.step(life, {:owner, lease.epoch, token, {:written, 5}})
      {:ok, life, _} = Lifecycle.step(life, {:owner, lease.epoch, token, :retire})
      %{record | life: life}
    else
      %{record | life: life}
    end
  end
end
