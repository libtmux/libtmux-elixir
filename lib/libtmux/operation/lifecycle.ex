defmodule LibTmux.Operation.Lifecycle do
  @moduledoc false

  alias LibTmux.{Deadline, Error}

  # This record has one initial waiter. A host owns later waiter registrations.
  # Wire retirement does not prove native cleanup or permit replacement admission.
  # The router must qualify and correlate a reply before submitting its owner event.

  @enforce_keys [:epoch, :token, :deadline, :line_bytes, :limits]
  defstruct [
    :epoch,
    :token,
    :deadline,
    :line_bytes,
    :limits,
    :result,
    :closing_reason,
    wire: :unsent,
    written: 0,
    waiter: :waiting
  ]

  @type action :: {:settle, {:ok, map()} | {:error, Error.t()}} | :close_epoch
  @opaque t :: %__MODULE__{}

  @doc false
  def new(epoch, token, %Deadline{} = deadline, line_bytes, options \\ []) do
    limits =
      options |> Keyword.validate!(max_reply_bytes: 65_536, max_reply_lines: 1024) |> Map.new()

    unless (is_reference(epoch) or is_atom(epoch)) and not is_nil(epoch) and
             (is_reference(token) or is_atom(token)) and not is_nil(token) and
             is_integer(line_bytes) and line_bytes in 1..65_536 and
             is_integer(limits.max_reply_bytes) and limits.max_reply_bytes in 0..1_048_576 and
             is_integer(limits.max_reply_lines) and limits.max_reply_lines in 1..4096,
           do: raise(ArgumentError, "invalid operation identity or byte/line limits")

    %__MODULE__{
      epoch: epoch,
      token: token,
      deadline: deadline,
      line_bytes: line_bytes,
      limits: limits
    }
  end

  @doc false
  @spec step(t(), term(), keyword()) :: {:ok, t(), [action()]} | {:error, Error.t()}
  def step(operation, event, options \\ [])

  def step(%__MODULE__{} = operation, {:owner, epoch, token, event}, options) do
    cond do
      epoch != operation.epoch ->
        rejected(:stale_epoch)

      token != operation.token ->
        rejected(:stale_operation)

      event in [:dispatch, :retire] or match?({:written, _}, event) or
          match?({:reply, _, _, _}, event) ->
        apply_event(operation, event, options)

      true ->
        rejected(:invalid_transition)
    end
  end

  def step(%__MODULE__{} = operation, event, options) do
    cond do
      match?({:epoch_closed, _}, event) and elem(event, 1) != operation.epoch ->
        rejected(:stale_epoch)

      event in [:cancel_waiter, :cancel_operation, :expire] or match?({:epoch_closed, _}, event) ->
        apply_event(operation, event, options)

      true ->
        rejected(:invalid_transition)
    end
  end

  defp apply_event(operation, event, options) do
    if expires?(operation, event, options),
      do: expire(operation),
      else: transition(operation, event)
  end

  @doc false
  def wire_retired?(%__MODULE__{wire: :retired, result: result}), do: not is_nil(result)
  def wire_retired?(%__MODULE__{}), do: false

  defp expires?(%{wire: wire} = operation, event, options)
       when wire in [:unsent, :writing, :awaiting] do
    event != :cancel_waiter and not match?({:epoch_closed, _}, event) and
      Deadline.remaining(operation.deadline, options) == 0
  end

  defp expires?(_operation, _event, _options), do: false

  defp transition(%{wire: :unsent, result: nil} = operation, :dispatch),
    do: accepted(%{operation | wire: :writing})

  defp transition(%{wire: :writing} = operation, {:written, bytes})
       when is_integer(bytes) and bytes > 0 do
    count = operation.written + bytes

    if count <= operation.line_bytes do
      accepted(%{
        operation
        | written: count,
          wire: if(count == operation.line_bytes, do: :awaiting, else: :writing)
      })
    else
      rejected(:invalid_transition)
    end
  end

  # A qualified reply can precede the native write acknowledgement. Its logical
  # result is final; only acknowledged bytes advance the writer or retire wire.
  defp transition(%{wire: wire, result: nil} = operation, {:reply, status, guard, lines})
       when wire in [:writing, :awaiting] and status in [:ok, :error] do
    with :ok <- reply_size(operation, guard, lines) do
      result = %{
        outcome: if(status == :ok, do: :completed, else: :failed),
        certainty: :acknowledged,
        evidence: :command_reply,
        guard: guard,
        lines: lines
      }

      settle(%{operation | result: result}, {:ok, result})
    end
  end

  defp transition(%{wire: :awaiting, result: result} = operation, :retire)
       when not is_nil(result),
       do: accepted(%{operation | wire: :retired})

  defp transition(operation, :cancel_waiter),
    do: settle(operation, {:error, failure(:cancelled, operation)})

  defp transition(%{result: nil, wire: :unsent} = operation, :cancel_operation),
    do: skip(operation, :cancelled)

  defp transition(%{result: nil, wire: wire} = operation, :cancel_operation)
       when wire in [:writing, :awaiting],
       do: accepted(%{operation | wire: :closing, closing_reason: :cancelled}, [:close_epoch])

  defp transition(%{wire: :closing} = operation, :cancel_operation), do: accepted(operation)

  defp transition(%{result: result} = operation, :cancel_operation) when not is_nil(result),
    do: accepted(operation)

  defp transition(operation, {:epoch_closed, _epoch}) do
    operation =
      if is_nil(operation.result) do
        %{
          operation
          | result: %{
              outcome: if(operation.wire == :unsent, do: :skipped, else: :unknown),
              certainty: certainty(operation),
              evidence: :epoch_closed
            }
        }
      else
        operation
      end

    response =
      if operation.result.outcome in [:completed, :failed],
        do: {:ok, operation.result},
        else: {:error, failure(operation.closing_reason || :disconnected, operation)}

    settle(%{operation | wire: :retired}, response)
  end

  defp transition(%{result: result} = operation, :expire) when not is_nil(result),
    do: accepted(operation)

  defp transition(%{wire: :closing} = operation, :expire), do: accepted(operation)
  defp transition(_operation, _event), do: rejected(:invalid_transition)

  defp expire(%{wire: :unsent} = operation), do: skip(operation, :timeout)

  defp expire(operation) do
    {operation, actions} = settlement(operation, {:error, failure(:timeout, operation)})
    accepted(%{operation | wire: :closing, closing_reason: :timeout}, actions ++ [:close_epoch])
  end

  defp skip(operation, kind) do
    result = %{outcome: :skipped, certainty: :no_write, evidence: kind}
    settle(%{operation | result: result, wire: :retired}, {:error, failure(kind, operation)})
  end

  defp settle(operation, response) do
    {operation, actions} = settlement(operation, response)
    accepted(operation, actions)
  end

  defp settlement(%{waiter: :waiting} = operation, response),
    do: {%{operation | waiter: :settled}, [{:settle, response}]}

  defp settlement(operation, _response), do: {operation, []}

  defp certainty(%{wire: :unsent}), do: :no_write
  defp certainty(%{result: %{certainty: certainty}}), do: certainty
  defp certainty(_operation), do: :unknown

  defp failure(kind, operation),
    do: %Error{kind: kind, phase: :operation, certainty: certainty(operation)}

  defp accepted(operation, actions \\ []), do: {:ok, operation, actions}
  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :operation, certainty: :no_write}}

  defp reply_size(operation, {time, number, flags}, lines)
       when is_integer(time) and time in 0..99_999_999_999_999_999_999 and
              is_integer(number) and number in 0..99_999_999_999_999_999_999 and
              is_integer(flags) and flags in 0..99_999_999_999_999_999_999 and is_list(lines) do
    if length(lines) <= operation.limits.max_reply_lines and Enum.all?(lines, &is_binary/1) and
         Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2)) <= operation.limits.max_reply_bytes,
       do: :ok,
       else: {:error, %Error{kind: :resource_limit, phase: :operation, certainty: :unknown}}
  end

  defp reply_size(_operation, _guard, _lines), do: rejected(:invalid_transition)
end
