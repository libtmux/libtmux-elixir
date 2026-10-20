defmodule LibTmux.Control do
  @moduledoc """
  A connection handle pinned to one qualified control epoch.

  `submit/3` returns a retained `LibTmux.Operation` after bounded admission.
  It never retries, refreshes, attaches, creates sessions or changes transport.
  `request_close/1` closes write authority for the entire pinned epoch through
  reserved capacity; it does not prove retirement or roll back effects.

  Connection construction and its public startup factory remain under
  implementation. The internal descriptor constructor accepts only an already
  ready connection. Its host must qualify the server's effective hooks, aliases
  and stream writers for the whole lane; a pinned handle is not authentication
  against unqualified command output or arbitrary writes to internal tables.
  """

  alias LibTmux.{Deadline, Error, Operation}
  alias LibTmux.Control.{Admission, Exchange, Lifetime, Request}

  @enforce_keys [:owner, :view, :lifetime, :endpoint]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{}

  @doc false
  def from_descriptor(%{owner: owner, view: view, lifetime: lifetime}) do
    with {:ok, endpoint} <- read(owner, view, lifetime),
         :ok <- ready(endpoint),
         {:ok, _template} <- Operation.prepare(endpoint) do
      {:ok, %__MODULE__{owner: owner, view: view, lifetime: lifetime, endpoint: endpoint}}
    end
  end

  @doc """
  Admits one request and returns its retained operation handle.

  `timeout` defaults to 5000ms and covers validation, admission, queueing,
  writes and replies under one monotonic deadline. Request binaries are
  detached before publication. Invalid input, overload or stale context before
  admission returns a no-write error. Every successful admission returns its
  Operation, even if its context disappears before publication. Inspect that
  handle for the eventual canonical result or an explicit lost-context error.

  Closing the connection can affect sibling operations. Command replies do
  not prove external program exit. Caller timeout does not authorize replay.
  """
  @spec submit(t(), Request.t(), keyword()) :: {:ok, Operation.t()} | {:error, Error.t()}
  def submit(%__MODULE__{} = control, %Request{} = request, options \\ []) do
    entered_at = System.monotonic_time(:millisecond)
    options = Keyword.validate!(options, timeout: 5000)
    deadline = Deadline.new(options[:timeout], now: entered_at)

    with :ok <- unexpired(deadline),
         {:ok, endpoint} <- current(control),
         :ok <- ready(endpoint),
         {:ok, request, line} <- Request.prepare(request, endpoint.instance),
         {:ok, template} <- Operation.prepare(endpoint),
         {:ok, lease} <-
           Admission.claim(
             endpoint.pool,
             endpoint.epoch,
             endpoint.router,
             deadline,
             byte_size(line)
           ) do
      operation = Operation.bind(template, lease)
      publish(control, endpoint, lease, request, deadline)
      {:ok, operation}
    else
      {:error, %Error{} = error} -> {:error, %{error | certainty: :no_write}}
      {:error, _reason} -> failure(:resource_limit)
    end
  end

  @doc "Admits a request or raises the same structured error."
  def submit!(control, request, options \\ []), do: unwrap(submit(control, request, options))

  @doc "Reads the pinned epoch's current phase and identity without contacting tmux."
  @spec status(t()) :: {:ok, map()} | {:error, Error.t()}
  def status(%__MODULE__{} = control) do
    result =
      with {:ok, endpoint} <- current(control) do
        %{generation: generation, phase: phase} = Lifetime.status(control.lifetime)

        if generation == endpoint.generation do
          {:ok,
           %{
             epoch: endpoint.epoch,
             generation: generation,
             phase: phase,
             instance: endpoint.instance
           }}
        else
          failure(:stale_connection)
        end
      end

    case result do
      {:error, %Error{} = error} -> {:error, %{error | phase: :status, certainty: :unknown}}
      success -> success
    end
  end

  @doc "Reads pinned connection status or raises the same structured error."
  def status!(control), do: unwrap(status(control))

  @doc """
  Requests whole-epoch closure without claiming an operation or metadata slot.

  Repeated requests for the same closing or proven-retired generation return
  `:ok`. Success is a request or previously known retirement, not a cleanup
  acknowledgement. A replacement Manager or epoch is never followed.
  """
  @spec request_close(t()) :: :ok | {:error, Error.t()}
  def request_close(%__MODULE__{} = control) do
    result =
      with {:ok, endpoint} <- current(control) do
        case Lifetime.status(control.lifetime) do
          %{generation: generation, phase: :retired} when generation == endpoint.generation ->
            :ok

          _ ->
            Lifetime.revoke(control.lifetime, endpoint.generation)
        end
      end

    case result do
      {:error, %Error{} = error} -> {:error, %{error | phase: :close, certainty: :unknown}}
      :ok -> :ok
    end
  end

  @doc "Requests epoch closure or raises the same structured error."
  def request_close!(control), do: unwrap(request_close(control))

  @doc """
  Requests closure and waits for proven retirement of the pinned epoch.

  `timeout` defaults to 5000ms. The original budget includes validation and
  retirement waiting. Closure still happens if the bounded metadata wait cannot
  be admitted. Timeout, overload or lost ownership reports unknown certainty;
  it never proves cleanup. `:ok` requires known native and actor retirement.

  The connection supervisor and retained records remain available for explicit
  reconnect and inspection. This does not stop the supervisor or roll back
  sibling effects.
  """
  @spec close(t(), keyword()) :: :ok | {:error, Error.t()}
  def close(%__MODULE__{} = control, options \\ []) do
    deadline = lifecycle_deadline(options)

    result =
      with :ok <- request_close(control),
           {:ok, endpoint} <- current(control) do
        case Lifetime.status(control.lifetime) do
          %{generation: generation, phase: :retired} when generation == endpoint.generation ->
            unexpired(deadline)

          _ ->
            Exchange.call(endpoint.inbox, endpoint.epoch, deadline, {:connection, :retired})
        end
      end

    lifecycle_result(result, :close)
  end

  @doc "Waits for retirement or raises the same structured error."
  def close!(control, options \\ []), do: unwrap(close(control, options))

  @doc """
  Explicitly obtains the ready epoch, starting a replacement only after retirement.

  A ready epoch returns itself. Call `close/2` first to require replacement.
  The default 5000ms budget covers metadata admission, retirement and startup.
  A successful reply pins the acknowledged endpoint even if it becomes stale
  before this caller resumes. It never follows a later view or replays work.
  Errors report unknown certainty about existing effects. Attachment counts
  include the control client; reconnect can attach one replacement client.
  """
  @spec reconnect(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def reconnect(%__MODULE__{} = control, options \\ []) do
    deadline = lifecycle_deadline(options)

    result =
      with {:ok, endpoint} <- current(control),
           {:ok, acknowledged} <-
             Exchange.call(endpoint.inbox, endpoint.epoch, deadline, {:reconnect, nil}) do
        bind_reconnected(control, acknowledged)
      end

    lifecycle_result(result, :connect)
  end

  @doc "Obtains the ready epoch or raises the same structured error."
  def reconnect!(control, options \\ []), do: unwrap(reconnect(control, options))

  defp bind_reconnected(control, acknowledged) do
    shared = [:manager, :pool, :records, :inbox, :waiter_inbox, :lifetime]
    original = control.endpoint

    epoch_matches =
      (acknowledged.generation == original.generation and acknowledged.epoch == original.epoch) or
        (acknowledged.generation == original.generation + 1 and
           acknowledged.epoch != original.epoch)

    if acknowledged.phase == :ready and epoch_matches and
         Map.take(acknowledged, shared) === Map.take(original, shared),
       do: {:ok, %{control | endpoint: acknowledged}},
       else: failure(:invalid_reply)
  end

  defp lifecycle_deadline(options) do
    entered_at = System.monotonic_time(:millisecond)
    options = Keyword.validate!(options, timeout: 5000)
    Deadline.new(options[:timeout], now: entered_at)
  end

  defp lifecycle_result({:error, %Error{} = error}, phase),
    do: {:error, %{error | phase: phase, certainty: :unknown}}

  defp lifecycle_result(result, _phase), do: result

  defp publish(control, endpoint, lease, request, deadline) do
    with {:ok, ^endpoint} <- current(control),
         :ok <- ready(endpoint),
         {:ok, :reserved} <- Admission.state(endpoint.pool, lease),
         true <- Deadline.remaining(deadline) > 0 do
      send(endpoint.router, {:submit, endpoint.epoch, lease, request})
    end

    :ok
  end

  defp current(control) do
    with {:ok, endpoint} <- read(control.owner, control.view, control.lifetime) do
      if Map.drop(endpoint, [:phase, :births]) === Map.drop(control.endpoint, [:phase, :births]),
        do: {:ok, endpoint},
        else: failure(:stale_connection)
    end
  end

  defp read(owner, view, lifetime) do
    case :ets.info(view, :owner) do
      :undefined ->
        failure(:connection_lost)

      ^owner ->
        with [{:context, %{owner: ^owner, lifetime: ^lifetime}}] <- :ets.lookup(view, :context),
             [{:connection, %{lifetime: ^lifetime, manager: manager} = endpoint}] <-
               :ets.lookup(view, :connection),
             true <- Process.alive?(owner) and Process.alive?(manager) do
          {:ok, endpoint}
        else
          _ -> failure(:stale_connection)
        end

      _ ->
        failure(:wrong_connection)
    end
  rescue
    ArgumentError -> failure(:connection_lost)
  end

  defp ready(%{phase: :ready} = endpoint) do
    if Lifetime.allows_write?(endpoint.lifetime, endpoint.generation),
      do: :ok,
      else: failure(:stale_epoch)
  end

  defp ready(_endpoint), do: failure(:not_ready)

  defp unexpired(deadline),
    do: if(Deadline.remaining(deadline) > 0, do: :ok, else: failure(:timeout))

  defp failure(kind), do: {:error, %Error{kind: kind, phase: :admission, certainty: :no_write}}
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: raise(error)
  defp unwrap(:ok), do: :ok
end
