defmodule LibTmux.OperationLifecycleTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Operation.Lifecycle

  test "a cancelled waiter settles once while later acknowledgement classifies the operation" do
    operation = operation()

    assert {:ok, operation, []} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, :dispatch}, now: 1)

    assert {:ok, operation, []} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, {:written, 8}}, now: 2)

    assert {:ok, operation, [{:settle, {:error, %Error{kind: :cancelled}}}]} =
             Lifecycle.step(operation, :cancel_waiter, now: 3)

    assert operation.result == nil
    assert {:ok, operation, []} = Lifecycle.step(operation, :cancel_waiter, now: 4)

    assert {:ok, operation, []} =
             Lifecycle.step(
               operation,
               {:owner, :epoch, :operation, {:reply, :ok, {1, 2, 1}, ["done"]}},
               now: 5
             )

    assert operation.result == %{
             outcome: :completed,
             certainty: :acknowledged,
             evidence: :command_reply,
             guard: {1, 2, 1},
             lines: ["done"]
           }

    refute Lifecycle.wire_retired?(operation)

    assert {:ok, operation, []} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, :retire}, now: 6)

    assert Lifecycle.wire_retired?(operation)

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(
               operation,
               {:owner, :epoch, :operation, {:reply, :error, {1, 2, 1}, []}},
               now: 7
             )
  end

  test "partial-line cancellation closes its epoch before another request can write" do
    {:ok, operation, []} =
      Lifecycle.step(operation(), {:owner, :epoch, :operation, :dispatch}, now: 1)

    assert {:error, %Error{kind: :stale_epoch}} =
             Lifecycle.step(operation, {:owner, :replacement, :operation, {:written, 8}}, now: 2)

    assert {:error, %Error{kind: :stale_operation}} =
             Lifecycle.step(operation, {:owner, :epoch, :different, {:reply, :ok, {1, 2, 1}, []}},
               now: 2
             )

    assert {:error, %Error{kind: :stale_epoch}} =
             Lifecycle.step(operation, {:owner, :replacement, :operation, :retire}, now: 2)

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:written, 8}, now: 2)

    {:ok, operation, []} =
      Lifecycle.step(operation, {:owner, :epoch, :operation, {:written, 3}}, now: 2)

    assert {:ok, operation, [:close_epoch]} = Lifecycle.step(operation, :cancel_operation, now: 3)
    assert operation.result == nil
    assert operation.written == 3

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, {:written, 5}}, now: 4)

    assert {:error, %Error{kind: :stale_epoch}} =
             Lifecycle.step(operation, {:owner, :replacement, :operation, :dispatch}, now: 4)

    assert {:ok, operation, [{:settle, {:error, %Error{certainty: :unknown}}}]} =
             Lifecycle.step(operation, {:epoch_closed, :epoch}, now: 5)

    assert operation.result.outcome == :unknown
    assert operation.wire == :retired

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, {:reply, :ok, {1, 2, 1}, []}},
               now: 6
             )
  end

  test "unsent cancellation proves no write and never admits the cancelled token" do
    assert {:ok, operation, [{:settle, {:error, %Error{kind: :cancelled, certainty: :no_write}}}]} =
             Lifecycle.step(operation(), :cancel_operation, now: 1)

    assert operation.result.outcome == :skipped
    assert Lifecycle.wire_retired?(operation)

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, :dispatch}, now: 2)
  end

  test "one original deadline covers queueing, writing and reply evidence" do
    assert {:ok, unsent, [{:settle, {:error, %Error{kind: :timeout, certainty: :no_write}}}]} =
             Lifecycle.step(operation(), :expire, now: 100)

    assert unsent.result.outcome == :skipped
    {:ok, sent, []} = Lifecycle.step(operation(), {:owner, :epoch, :operation, :dispatch}, now: 1)
    {:ok, sent, []} = Lifecycle.step(sent, {:owner, :epoch, :operation, {:written, 8}}, now: 2)

    assert {:ok, sent,
            [{:settle, {:error, %Error{kind: :timeout, certainty: :unknown}}}, :close_epoch]} =
             Lifecycle.step(sent, {:owner, :epoch, :operation, {:reply, :ok, {1, 2, 1}, []}},
               now: 100
             )

    assert sent.result == nil
    assert {:ok, sent, []} = Lifecycle.step(sent, {:epoch_closed, :epoch}, now: 101)
    assert sent.result.outcome == :unknown

    {:ok, proven, []} =
      Lifecycle.step(operation(), {:owner, :epoch, :operation, :dispatch}, now: 1)

    {:ok, proven, []} =
      Lifecycle.step(proven, {:owner, :epoch, :operation, {:written, 8}}, now: 2)

    {:ok, proven, _actions} =
      Lifecycle.step(proven, {:owner, :epoch, :operation, {:reply, :ok, {1, 2, 1}, []}}, now: 3)

    result = proven.result

    assert {:ok, late_retirement, [:close_epoch]} =
             Lifecycle.step(proven, {:owner, :epoch, :operation, :retire}, now: 100)

    assert late_retirement.result == result
    assert {:ok, proven, [:close_epoch]} = Lifecycle.step(proven, :expire, now: 100)
    assert proven.result == result
    assert {:ok, proven, []} = Lifecycle.step(proven, {:epoch_closed, :epoch}, now: 101)
    assert proven.result == result
  end

  test "write tokens, exact byte progress and retained replies have finite bounds" do
    assert {:error, %Error{kind: :stale_operation}} =
             Lifecycle.step(operation(), {:owner, :epoch, :different, :dispatch}, now: 1)

    {:ok, operation, []} =
      Lifecycle.step(operation(), {:owner, :epoch, :operation, :dispatch}, now: 1)

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, {:written, 9}}, now: 2)

    {:ok, operation, []} =
      Lifecycle.step(operation, {:owner, :epoch, :operation, {:written, 8}}, now: 2)

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(
               operation,
               {:owner, :epoch, :operation,
                {:reply, :ok, {100_000_000_000_000_000_000, 2, 1}, []}},
               now: 3
             )

    assert {:error, %Error{kind: :resource_limit}} =
             Lifecycle.step(
               operation,
               {:owner, :epoch, :operation,
                {:reply, :ok, {1, 2, 1}, [String.duplicate("x", 17)]}},
               now: 3
             )

    assert {:error, %Error{kind: :invalid_transition}} =
             Lifecycle.step(operation, {:owner, :epoch, :operation, :retire}, now: 3)

    assert {:ok, operation, [{:settle, {:ok, result}}]} =
             Lifecycle.step(
               operation,
               {:owner, :epoch, :operation, {:reply, :error, {1, 2, 1}, ["missing"]}},
               now: 3
             )

    assert result.outcome == :failed
    assert operation.result == result
    {:ok, operation, []} = Lifecycle.step(operation, {:epoch_closed, :epoch}, now: 4)
    assert operation.result == result
  end

  defp operation do
    Lifecycle.new(:epoch, :operation, Deadline.new(100, now: 0), 8,
      max_reply_bytes: 16,
      max_reply_lines: 4
    )
  end
end
