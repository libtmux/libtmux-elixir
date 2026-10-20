defmodule LibTmux.Control.Waiters do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Inbox, Records}
  alias LibTmux.Operation.Lifecycle

  def new(%Records{} = records, capacity) do
    unless :ets.info(records.table, :owner) == self() and
             :ets.lookup(records.table, :context) == [{:context, records}],
           do: raise(ArgumentError, "waiters require the current record owner")

    %{
      records: records,
      inbox: Inbox.new(capacity, kinds: [:await], max_outcome_bytes: 131_072),
      active: %{},
      fault: nil
    }
  end

  def turn(state, options \\ []) do
    state = accept(state, options)

    Enum.reduce(state.active, state, fn {_key, %{ticket: ticket, lease: lease}}, state ->
      case Inbox.closed?(state.inbox, ticket) do
        {:ok, true} ->
          finish(state, ticket, failure(:cancelled), options)

        {:ok, false} ->
          if Deadline.remaining(%Deadline{expires_at: ticket.expires_at}, options) == 0,
            do: finish(state, ticket, failure(:timeout), options),
            else: refresh(state, ticket, lease, options)

        {:error, error} ->
          %{state | fault: error}
      end
    end)
  end

  def forget(state, lease, options \\ []) do
    state = turn(state, options)

    if state.fault do
      {state, {:error, state.fault}}
    else
      case Records.fetch(state.records, lease) do
        {:ok, record} ->
          # This exact retired result is immutable. A prior pending sweep is not.
          if Lifecycle.wire_retired?(record.life) do
            state = settle(state, lease, record.life.result, options)

            if state.fault,
              do: {state, {:error, state.fault}},
              else: {state, Records.forget(state.records, lease)}
          else
            {state, failure(:wire_active)}
          end

        :pending ->
          {state, failure(:wire_active)}

        error ->
          {state, error}
      end
    end
  end

  defp accept(%{fault: error} = state, _options) when not is_nil(error), do: state

  defp accept(state, options) do
    with {:ok, _count} <- Inbox.reap(state.inbox),
         {:ok, work} <- Inbox.take(state.inbox, options) do
      Enum.reduce(work, state, fn {ticket, {:await, lease}}, state ->
        case if(ticket.epoch == lease.epoch,
               do: Records.fetch(state.records, lease),
               else: failure(:stale_operation)
             ) do
          {:error, _error} = outcome ->
            finish(state, ticket, outcome, options)

          _current ->
            %{state | active: Map.put(state.active, key(ticket), %{ticket: ticket, lease: lease})}
        end
      end)
    else
      {:error, error} -> %{state | fault: error}
    end
  end

  defp refresh(state, ticket, lease, options) do
    case Records.fetch(state.records, lease) do
      {:ok, %{life: %{result: result}}} when not is_nil(result) ->
        finish(state, ticket, {:ok, result}, options)

      {:error, _error} = outcome ->
        finish(state, ticket, outcome, options)

      _pending ->
        state
    end
  end

  defp settle(state, lease, result, options) do
    Enum.reduce(state.active, state, fn
      {_key, %{ticket: ticket, lease: ^lease}}, state ->
        finish(state, ticket, {:ok, result}, options)

      _other, state ->
        state
    end)
  end

  defp finish(state, ticket, outcome, options) do
    case Inbox.finish(state.inbox, ticket, outcome, options) do
      :ok -> %{state | active: Map.delete(state.active, key(ticket))}
      {:error, error} -> %{state | fault: error}
    end
  end

  defp key(ticket), do: {ticket.slot, ticket.generation}
  defp failure(kind), do: {:error, %Error{kind: kind, phase: :wait, certainty: :unknown}}
end
