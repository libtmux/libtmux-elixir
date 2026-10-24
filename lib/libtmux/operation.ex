defmodule LibTmux.Operation do
  @moduledoc """
  A retained operation handle pinned to its original owner, tables and epoch.

  `result/1` and `status/1` read local retained values. `await/2` owns a separate
  bounded waiter; its timeout never stops the operation. `stop/1` requests
  closure of the operation's entire connection epoch, including siblings.
  It does not roll back effects or prove native cleanup.

  Canonical results carry `outcome`, `certainty` and `evidence`. Completed,
  failed, skipped and unknown outcomes remain values, including in bang APIs.
  Bang functions raise only API or metadata errors. A command reply is distinct
  from wire retirement and arbitrary program exit.

  Normal reconnect preserves retained records until forget or expiry. Owner
  replacement loses those tables; a handle never follows a replacement view.
  Handles recovered from `LibTmux.Control.execute/3` errors also remain owned
  by that original caller: its death permits reclamation after wire retirement.
  """

  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Admission, Births, Exchange, Inbox, Lifetime, Records}
  alias LibTmux.Operation.Lifecycle

  @enforce_keys [:records, :lease, :inbox, :waiter_inbox, :births]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
  @typedoc "A retained owner-bound operation handle; it is not a command result or a reservation."
  @opaque t :: %__MODULE__{}
  @typedoc "A qualified command reply, independently of wire retirement or program completion."
  @type command_result :: %{
          outcome: :completed | :failed,
          certainty: :acknowledged,
          evidence: :command_reply,
          guard: LibTmux.Protocol.guard_id(),
          lines: [binary()]
        }
  @typedoc "A canonical no-write outcome, with the reason it was skipped before dispatch."
  @type skipped_result :: %{
          outcome: :skipped,
          certainty: :no_write,
          evidence: :cancelled | :timeout | :epoch_closed
        }
  @typedoc "An epoch closed without enough evidence to classify the operation's effects."
  @type unknown_result :: %{outcome: :unknown, certainty: :unknown, evidence: :epoch_closed}
  @typedoc "The immutable canonical outcome; failed, skipped and unknown outcomes remain values."
  @type result :: command_result() | skipped_result() | unknown_result()
  @typedoc "Wire progress for this operation; retired wire does not prove connection cleanup."
  @type wire :: :unpublished | :unsent | :writing | :awaiting | :closing | :retired
  @typedoc "Retained wire progress and the canonical result, or nil while no outcome is established."
  @type status :: %{wire: wire(), result: result() | nil}
  @typedoc "A positive millisecond budget for one waiter or record-reclamation call."
  @type option :: {:timeout, pos_integer()}

  @doc false
  def new(endpoint, %Admission.Lease{} = lease) do
    with {:ok, template} <- prepare(endpoint),
         true <- endpoint.epoch === lease.epoch and endpoint.router === lease.destination,
         current when current == :pending or is_tuple(current) <-
           Records.fetch(endpoint.records, lease) do
      case current do
        {:error, _error} -> raise ArgumentError, "operation requires a current admitted lease"
        _ -> bind(template, lease)
      end
    else
      _ -> raise ArgumentError, "operation requires matching Manager and epoch resources"
    end
  end

  @doc false
  def prepare(endpoint) do
    operation = %__MODULE__{
      records: endpoint.records,
      lease: nil,
      inbox: endpoint.inbox,
      waiter_inbox: endpoint.waiter_inbox,
      births: endpoint.births
    }

    valid =
      endpoint.manager == operation.records.pool.owner and
        endpoint.pool === operation.records.pool and
        endpoint.epoch === operation.births.epoch and
        endpoint.lifetime === operation.births.lifetime and
        endpoint.generation === operation.births.generation

    with true <- valid,
         :ok <- Records.validate(operation.records),
         :ok <- inbox_context(operation, operation.inbox, :forget),
         :ok <- inbox_context(operation, operation.waiter_inbox, :await),
         {:ok, %{roles: %{router: router}}} <- Births.snapshot(operation.births),
         true <- operation.births.owner == endpoint.manager and router === endpoint.router do
      {:ok, operation}
    else
      false -> failure(:wrong_operation)
      error -> error
    end
  end

  # Admission already produced this exact lease. Binding performs no live reads.
  @doc false
  def bind(
        %__MODULE__{lease: nil, records: records, births: births} = template,
        %Admission.Lease{} = lease
      )
      when lease.table == records.pool.table and lease.epoch == births.epoch,
      do: %{template | lease: lease}

  @doc """
  Reads retained wire state and canonical result without contacting tmux.

  See the [worked example](advanced-execution.html).
  """
  @spec status(t()) :: {:ok, status()} | {:error, Error.t()}
  def status(%__MODULE__{} = operation) do
    case Records.fetch(operation.records, operation.lease) do
      :pending -> {:ok, %{wire: :unpublished, result: nil}}
      {:ok, %{life: life}} -> {:ok, %{wire: life.wire, result: life.result}}
      error -> normalize(error, :operation)
    end
  end

  @doc """
  Reads retained status or raises the same structured error.

  See the [worked example](advanced-execution.html).
  """
  @spec status!(t()) :: status()
  def status!(operation), do: unwrap(status(operation))

  @doc """
  Returns a canonical result, `:pending`, or a retained-context error.

  See the [worked example](advanced-execution.html).
  """
  @spec result(t()) :: :pending | {:ok, result()} | {:error, Error.t()}
  def result(%__MODULE__{} = operation) do
    case status(operation) do
      {:ok, %{result: nil}} -> :pending
      {:ok, %{result: result}} -> {:ok, result}
      error -> error
    end
  end

  @doc """
  Reads a result or `:pending`; raises API errors, preserving all canonical outcomes.

  See the [worked example](advanced-execution.html).
  """
  @spec result!(t()) :: :pending | result()
  def result!(operation), do: unwrap(result(operation))

  @doc """
  Waits for a canonical result under one positive millisecond timeout.

  The default is 5000ms. Every call claims an independent bounded waiter slot,
  including terminal operations; use `result/1` for immediate inspection.
  Completed waiter copies survive record reclamation until this caller reads
  them. Timeout, overload and caller death affect only this waiter.

  See the [worked example](advanced-execution.html).
  """
  @spec await(t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def await(%__MODULE__{} = operation, options \\ []) do
    deadline = deadline(options)
    exchange(operation, operation.waiter_inbox, :await, deadline, :wait)
  end

  @doc """
  Waits or raises API errors; canonical failed, skipped and unknown outcomes remain values.

  See the [worked example](advanced-execution.html).
  """
  @spec await!(t(), [option()]) :: result()
  def await!(operation, options \\ []), do: unwrap(await(operation, options))

  @doc false
  def collect(%__MODULE__{} = operation, %Deadline{} = deadline),
    do: exchange(operation, operation.waiter_inbox, :collect, deadline, :collect)

  @doc """
  Requests exact-record reclamation with a default 5000ms timeout.

  Wire-active records cannot be forgotten. An owner-accepted request remains
  owned after caller timeout. Successful reclamation invalidates this record
  handle while preserving already-accepted waiter copies.

  See the [worked example](advanced-execution.html).
  """
  @spec forget(t(), [option()]) :: :ok | {:error, Error.t()}
  def forget(%__MODULE__{} = operation, options \\ []) do
    deadline = deadline(options)
    exchange(operation, operation.inbox, :forget, deadline, :forget)
  end

  @doc """
  Forgets the retained record or raises the same structured error.

  See the [worked example](advanced-execution.html).
  """
  @spec forget!(t(), [option()]) :: :ok
  def forget!(operation, options \\ []), do: unwrap(forget(operation, options))

  @doc """
  Requests closure of the pinned epoch through reserved capacity.

  Returns `:ok` for an already wire-retired operation or an accepted closure
  request, and `{:error, error}` otherwise. Closure can affect sibling work;
  success does not prove retirement or change the canonical result. A stale
  handle cannot revoke a replacement epoch.

  See the [worked example](advanced-execution.html).
  """
  @spec stop(t()) :: :ok | {:error, Error.t()}
  def stop(%__MODULE__{} = operation) do
    result =
      case Records.fetch(operation.records, operation.lease) do
        {:ok, %{life: life}} ->
          if Lifecycle.wire_retired?(life), do: :ok, else: revoke(operation)

        :pending ->
          revoke(operation)

        error ->
          error
      end

    normalize(result, :stop)
  end

  @doc """
  Requests epoch closure or raises the same structured error.

  See the [worked example](advanced-execution.html).
  """
  @spec stop!(t()) :: :ok
  def stop!(operation), do: unwrap(stop(operation))

  defp revoke(operation) do
    with {:ok, births} <- stop_context(operation),
         do: Lifetime.revoke(births.lifetime, births.generation)
  end

  defp stop_context(%{births: %Births{} = births, records: records, lease: lease}) do
    with {:ok, %{roles: %{router: router}}} <- Births.snapshot(births) do
      if births.owner == records.pool.owner and births.epoch === lease.epoch and
           router === lease.destination,
         do: {:ok, births},
         else: failure(:wrong_operation)
    end
  end

  defp exchange(operation, inbox, kind, deadline, phase) do
    outcome =
      with :ok <- inbox_context(operation, inbox, kind),
           current when current == :pending or is_tuple(current) <-
             Records.fetch(operation.records, operation.lease) do
        case current do
          {:error, _error} = error -> error
          _ -> Exchange.call(inbox, operation.lease.epoch, deadline, {kind, operation.lease})
        end
      end

    normalize(outcome, phase)
  end

  defp inbox_context(operation, %Inbox{} = inbox, kind) do
    with :ok <- Inbox.validate(inbox) do
      if inbox.owner == operation.records.pool.owner and kind in inbox.kinds,
        do: :ok,
        else: failure(:wrong_operation)
    end
  end

  defp deadline(options) do
    options = Keyword.validate!(options, timeout: 5000)
    Deadline.new(options[:timeout])
  end

  defp normalize({:error, %Error{} = error}, phase) do
    certainty = if error.certainty == :no_write, do: :unknown, else: error.certainty
    {:error, %{error | phase: phase, certainty: certainty}}
  end

  defp normalize(outcome, _phase), do: outcome
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, %Error{} = error}), do: raise(error)
  defp unwrap(value), do: value
  defp failure(kind), do: {:error, %Error{kind: kind, certainty: :unknown}}
end
