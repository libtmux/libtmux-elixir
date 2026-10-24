defmodule LibTmux.ControlTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Action, Control, Deadline, Error, Operation, Pane, Ref}
  alias LibTmux.Control.{Admission, Births, Inbox, Lifetime, Records, Request, Waiters}

  test "status refuses terminal evidence tagged for another epoch or generation" do
    {control, endpoint, view} = connection()
    assert {:ok, %{terminal: :unavailable}} = Control.status(control)

    for {epoch, generation} <- [
          {make_ref(), endpoint.generation},
          {endpoint.epoch, endpoint.generation + 1}
        ] do
      :ets.insert(view, {:terminal, epoch, generation, %{reason: :old}})
      assert {:error, %{kind: :stale_connection}} = Control.status(control)
    end
  end

  test "split results bind only completed creation replies and preserve their evidence" do
    for {outcome, certainty, evidence, lines} <- [
          {:completed, :acknowledged, :command_reply, ["%7"]},
          {:failed, :acknowledged, :command_reply, ["can't find pane"]},
          {:skipped, :no_write, :timeout, []},
          {:unknown, :unknown, :epoch_closed, []}
        ] do
      {control, endpoint, _view} = connection()
      {:ok, pane} = Ref.new(:pane, "%0", "instance")
      observer = self()

      {caller, monitor} =
        spawn_monitor(fn -> send(observer, {:split, Pane.split(control, pane, timeout: 500)}) end)

      assert_receive {:submit, _, lease, _}
      table = endpoint.waiter_inbox.table
      assert_receive {Inbox, :wake, ^table, _}
      assert {:ok, [{ticket, {:collect, ^lease}}]} = Inbox.take(endpoint.waiter_inbox)
      canonical = %{outcome: outcome, certainty: certainty, evidence: evidence, lines: lines}
      assert :ok = Inbox.finish(endpoint.waiter_inbox, ticket, {:ok, canonical})
      assert_receive {:split, response}

      result =
        if outcome == :completed do
          assert {:ok, result} = response
          result
        else
          assert {:error, %Action.CompletionError{result: result}} = response
          result
        end

      assert result.details == canonical
      refute Map.has_key?(result, :ref)

      if outcome == :completed do
        assert result.value == %{
                 id: "%7",
                 ref: %Ref{entity: :pane, id: "%7", server_instance: "instance"}
               }

        assert Action.unwrap({:ok, result}) == result.value
      else
        assert result.value == nil
        error = assert_raise Action.CompletionError, fn -> Action.unwrap(response) end
        assert error.result === result
      end

      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    end
  end

  test "domain actions preserve pre-admission refusal and lost admitted context" do
    {control, endpoint, _view} = connection()
    {:ok, pane} = Ref.new(:pane, "%0", "instance")

    assert {:error, %Error{kind: :invalid_command, certainty: :no_write}} =
             Pane.split(control, pane, axis: :invalid)

    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(observer, {:execution, Pane.split(control, pane, timeout: 500)})
      end)

    assert_receive {:submit, _, lease, _}
    assert lease.mode == :managed
    table = endpoint.waiter_inbox.table
    assert_receive {Inbox, :wake, ^table, _}
    assert {:ok, [{ticket, {:collect, ^lease}}]} = Inbox.take(endpoint.waiter_inbox)
    :ets.delete(endpoint.records.table)
    :ok = Inbox.finish(endpoint.waiter_inbox, ticket, {:error, %Error{kind: :connection_lost}})

    assert_receive {:execution,
                    {:error,
                     %LibTmux.Control.ExecutionError{
                       context: :lost,
                       operation: operation,
                       error: %Error{kind: :connection_lost, certainty: :unknown}
                     } = error}}

    assert operation.lease == lease

    assert assert_raise(LibTmux.Control.ExecutionError, fn ->
             Action.unwrap({:error, error})
           end) === error

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  @tag lifecycle_api: true
  test "awaited close reports overload while reserved closure still takes effect" do
    {control, endpoint, _view} = connection()

    {:ok, held} =
      Inbox.publish(endpoint.inbox, endpoint.epoch, Deadline.new(500), {:reconnect, nil})

    try do
      assert {:error, %Error{kind: :resource_limit, phase: :close, certainty: :unknown}} =
               Control.close(control, timeout: 100)

      assert %{phase: :closing} = Lifetime.status(endpoint.lifetime)
      assert :ok = Lifetime.retired(endpoint.lifetime, endpoint.generation)
      assert :ok = Control.close(control, timeout: 100)
    after
      Inbox.close(endpoint.inbox, held)
    end
  end

  test "submission owns request binaries and returns a pinned unpublished operation" do
    {control, endpoint, _view} = connection()
    parent = :binary.copy("x", 1_000_000)
    value = binary_part(parent, 0, 4096)
    assert :binary.referenced_byte_size(value) > byte_size(value)

    assert {:ok, operation} =
             Control.submit(control, Request.set_user_option("@copy", value), timeout: 100)

    epoch = endpoint.epoch
    assert_receive {:submit, ^epoch, lease, request}, 0
    assert lease.publisher == self()
    assert {"@copy", ^value} = request.value
    assert :binary.referenced_byte_size(elem(request.value, 1)) == byte_size(value)

    assert {:ok, %{wire: :unpublished, result: nil}} = Operation.status(operation)

    assert {:error, %Error{kind: :resource_limit, certainty: :no_write}} =
             Control.submit(control, Request.field("pid"))

    refute_receive {:submit, _, _, _}, 0
  end

  test "invalid requests and stale handles cannot consume or publish work" do
    {control, endpoint, view} = connection()
    :ets.insert(view, {:connection, %{endpoint | phase: :starting}})
    assert {:error, %Error{kind: :not_ready}} = Control.from_descriptor(Map.from_struct(control))
    :ets.insert(view, {:connection, endpoint})

    assert {:error, %Error{kind: :invalid_command, certainty: :no_write}} =
             Control.submit(control, Request.field(~S"#{invalid"))

    {:ok, stale} = Ref.new(:pane, "%7", "old-instance")

    assert {:error, %Error{kind: :stale_target, certainty: :no_write}} =
             Control.submit(control, Request.field("pid", stale))

    assert {:ok, []} = Admission.entries(endpoint.pool)
    :ets.insert(view, {:connection, %{endpoint | epoch: make_ref()}})

    assert {:error, %Error{kind: :stale_connection, certainty: :no_write}} =
             Control.submit(control, Request.field("pid"))

    refute_receive {:submit, _, _, _}, 0
  end

  test "reserved closure works while admission and metadata capacity are full" do
    {control, endpoint, view} = connection()
    assert {:ok, operation} = Control.submit(control, Request.field("pid"))
    assert_receive {:submit, _, _, _}, 0

    {:ok, held} =
      Inbox.publish(endpoint.inbox, endpoint.epoch, Deadline.new(500), {:reconnect, nil})

    try do
      assert :ok = Control.request_close(control)
      assert :ok = Control.request_close(control)
      assert {:ok, %{phase: :closing}} = Control.status(control)
      assert :pending = Operation.result(operation)
      assert :ok = Lifetime.retired(endpoint.lifetime, endpoint.generation)
      assert :ok = Control.request_close(control)
      {:ok, replacement} = Lifetime.begin_epoch(endpoint.lifetime)
      assert :ok = Lifetime.ready(endpoint.lifetime, replacement)
      :ets.insert(view, {:connection, %{endpoint | generation: replacement, epoch: make_ref()}})

      assert {:error, %Error{kind: :stale_connection, certainty: :unknown}} =
               Control.request_close(control)

      assert Lifetime.allows_write?(endpoint.lifetime, replacement)
    after
      Inbox.close(endpoint.inbox, held)
    end
  end

  test "prevalidated operation binding remains pure after its context disappears" do
    {_control, endpoint, _view} = connection()
    assert {:ok, template} = Operation.prepare(endpoint)
    {:ok, lease} = Admission.claim(endpoint.pool, endpoint.epoch, self(), Deadline.new(100), 5)

    for table <- [endpoint.births.table, endpoint.records.table, endpoint.pool.table],
        do: :ets.delete(table)

    operation = Operation.bind(template, lease)

    assert {:error, %Error{kind: :connection_lost, certainty: :unknown}} =
             Operation.result(operation)
  end

  test "a handle cannot follow a replaced Manager or a lost Root view" do
    {control, endpoint, view} = connection()
    {:ok, operation} = Control.submit(control, Request.field("pid"))
    assert_receive {:submit, _, _, _}, 0
    replacement = spawn(fn -> :ok end)
    :ets.insert(view, {:connection, %{endpoint | manager: replacement}})

    assert {:error, %Error{kind: :stale_connection, phase: :status, certainty: :unknown}} =
             Control.status(control)

    assert {:error, %Error{kind: :stale_connection}} =
             Control.submit(control, Request.field("pid"))

    :ets.delete(view)

    assert {:error, %Error{kind: :connection_lost, phase: :status, certainty: :unknown}} =
             Control.status(control)

    assert :pending = Operation.result(operation)

    assert {:error, %Error{kind: :connection_lost, certainty: :no_write}} =
             Control.submit(control, Request.field("pid"))
  end

  defp connection do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    epoch = make_ref()
    births = Births.new(lifetime, generation, epoch, Deadline.new(500))
    :ok = Births.register(births, :router)
    :ok = Lifetime.ready(lifetime, generation)
    pool = Admission.new(1)
    records = Records.new(pool)
    inbox = Inbox.new(1, kinds: [:forget, :reconnect, :connection])
    waiters = Waiters.new(records, 1)

    endpoint = %{
      phase: :ready,
      manager: self(),
      router: self(),
      pool: pool,
      records: records,
      inbox: inbox,
      waiter_inbox: waiters.inbox,
      births: births,
      lifetime: lifetime,
      generation: generation,
      epoch: epoch,
      instance: "instance"
    }

    view = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(view, [{:context, %{owner: self(), lifetime: lifetime}}, {:connection, endpoint}])
    {:ok, control} = Control.from_descriptor(%{owner: self(), lifetime: lifetime, view: view})
    {control, endpoint, view}
  end
end
