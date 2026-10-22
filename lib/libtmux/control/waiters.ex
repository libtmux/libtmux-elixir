defmodule LibTmux.Control.Waiters do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Admission, Inbox, Records}
  alias LibTmux.Operation.Lifecycle

  def new(%Records{} = records, capacity) do
    unless :ets.info(records.table, :owner) == self() and
             :ets.lookup(records.table, :context) == [{:context, records}],
           do: raise(ArgumentError, "waiters require the current record owner")

    %{
      records: records,
      inbox: Inbox.new(capacity, kinds: [:await, :collect], max_outcome_bytes: 131_072),
      active: %{},
      publishers: %{},
      fault: nil
    }
  end

  def turn(state, options \\ []) do
    state = accept(state, options) |> watch_publishers()

    Enum.reduce(state.active, state, fn {key, %{ticket: ticket, lease: lease, kind: kind}},
                                        state ->
      case if(Map.has_key?(state.active, key),
             do: Inbox.closed?(state.inbox, ticket),
             else: :settled
           ) do
        {:ok, true} ->
          finish(state, ticket, failure(:cancelled), options)

        {:ok, false} ->
          if Deadline.remaining(%Deadline{expires_at: ticket.expires_at}, options) == 0,
            do: finish(state, ticket, failure(:timeout), options),
            else: refresh(state, ticket, lease, kind, options)

        {:error, error} ->
          %{state | fault: error}

        :settled ->
          state
      end
    end)
    |> reclaim_orphans(options)
  end

  def forget(state, lease, options \\ []) do
    state |> turn(options) |> forget_current(lease, options)
  end

  # Manager already serviced the Inbox once for this owner pass. Settle accepted
  # waiters against the exact retired record without repeating the whole scan.
  def forget_current(state, lease, options \\ [])

  def forget_current(%{fault: error} = state, _lease, _options) when not is_nil(error),
    do: {state, {:error, error}}

  def forget_current(state, lease, options) do
    case Inbox.validate(state.inbox) do
      :ok -> forget_retired(state, lease, options)
      {:error, error} -> {%{state | fault: error}, {:error, error}}
    end
  end

  defp forget_retired(state, lease, options) do
    case Records.fetch(state.records, lease) do
      {:ok, record} ->
        # This exact retired result is immutable. A prior pending sweep is not.
        if Lifecycle.wire_retired?(record.life) do
          reclaim(state, lease, record.life.result, options)
        else
          {state, failure(:wire_active)}
        end

      :pending ->
        {state, failure(:wire_active)}

      error ->
        {state, error}
    end
  end

  defp accept(%{fault: error} = state, _options) when not is_nil(error), do: state

  defp accept(state, options) do
    with {:ok, _count} <- Inbox.reap(state.inbox),
         {:ok, work} <- Inbox.take(state.inbox, options) do
      Enum.reduce(work, state, fn {ticket, {kind, lease}}, state ->
        case if(ticket.epoch == lease.epoch,
               do: Records.fetch(state.records, lease),
               else: failure(:stale_operation)
             ) do
          {:error, _error} = outcome ->
            finish(state, ticket, outcome, options)

          _current ->
            %{
              state
              | active:
                  Map.put(state.active, key(ticket), %{ticket: ticket, lease: lease, kind: kind})
            }
        end
      end)
    else
      {:error, error} -> %{state | fault: error}
    end
  end

  defp refresh(state, ticket, lease, :await, options) do
    case Records.fetch(state.records, lease) do
      {:ok, %{life: %{result: result}}} when not is_nil(result) ->
        finish(state, ticket, {:ok, result}, options)

      {:error, _error} = outcome ->
        finish(state, ticket, outcome, options)

      _pending ->
        state
    end
  end

  defp refresh(state, ticket, lease, :collect, options) do
    case Records.fetch(state.records, lease) do
      {:ok, %{life: %{wire: :retired, result: result}}} ->
        {state, _outcome} = reclaim(state, lease, result, options, false)
        state

      {:error, _error} = outcome ->
        finish(state, ticket, outcome, options)

      _pending ->
        state
    end
  end

  defp reclaim(state, lease, result, options, force \\ true) do
    state = settle(state, lease, result, options)

    collectors =
      for {_key, %{lease: ^lease, kind: :collect, ticket: ticket}} <- state.active, do: ticket

    {state, prepared} =
      Enum.reduce(collectors, {state, []}, fn ticket, {state, prepared} ->
        copy =
          case Inbox.closed?(state.inbox, ticket) do
            {:ok, true} -> failure(:cancelled)
            {:ok, false} -> Inbox.prepare(state.inbox, ticket, {:ok, result}, options)
            error -> error
          end

        case copy do
          {:error, %Error{kind: kind}} when kind in [:timeout, :cancelled] ->
            {finish(state, ticket, copy, options), prepared}

          _ ->
            {state, [{ticket, copy} | prepared]}
        end
      end)

    case Enum.find(prepared, fn {_ticket, copy} -> match?({:error, _}, copy) end) do
      {_ticket, {:error, error}} ->
        state =
          Enum.reduce(prepared, state, fn {ticket, _}, state ->
            finish(state, ticket, {:error, error}, options)
          end)

        {state, {:error, error}}

      nil when prepared == [] and not force ->
        {state, :ok}

      nil ->
        outcome =
          if state.fault, do: {:error, state.fault}, else: Records.forget(state.records, lease)

        state =
          Enum.reduce(prepared, state, fn {ticket, {:ok, copy}}, state ->
            published = if outcome == :ok, do: copy, else: outcome

            case Inbox.finish_prepared(state.inbox, ticket, published, options) do
              :ok -> %{state | active: Map.delete(state.active, key(ticket))}
              {:error, error} -> %{state | fault: error}
            end
          end)

        state = if outcome == :ok, do: unwatch(state, lease), else: state
        {state, outcome}
    end
  end

  defp settle(state, lease, result, options) do
    Enum.reduce(state.active, state, fn
      {_key, %{ticket: ticket, lease: ^lease, kind: :await}}, state ->
        case Inbox.closed?(state.inbox, ticket) do
          {:ok, true} -> finish(state, ticket, failure(:cancelled), options)
          {:ok, false} -> finish(state, ticket, {:ok, result}, options)
          {:error, error} -> %{state | fault: error}
        end

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

  # At most one monitor per admitted managed lease. Settlement and DOWN events
  # drive reclamation; existing owner accounting also finds unpublished leases.
  defp watch_publishers(%{fault: error} = state) when not is_nil(error), do: state

  defp watch_publishers(state) do
    case Admission.entries(state.records.pool) do
      {:ok, entries} ->
        managed = Map.new(for {_, %{mode: :managed} = lease} <- entries, do: {lease, true})

        state =
          Enum.reduce(Map.keys(state.publishers), state, fn lease, state ->
            if Map.has_key?(managed, lease), do: state, else: unwatch(state, lease)
          end)

        Enum.reduce(Map.keys(managed), state, fn lease, state ->
          if Map.has_key?(state.publishers, lease) do
            state
          else
            %{
              state
              | publishers: Map.put(state.publishers, lease, Process.monitor(lease.publisher))
            }
          end
        end)

      {:error, error} ->
        %{state | fault: error}
    end
  end

  defp reclaim_orphans(state, options) do
    Enum.reduce(Map.keys(state.publishers), state, fn lease, state ->
      if Process.alive?(lease.publisher) do
        state
      else
        {state, _outcome} = forget_current(state, lease, options)
        state
      end
    end)
  end

  defp unwatch(state, lease) do
    case Map.pop(state.publishers, lease) do
      {nil, _} ->
        state

      {monitor, publishers} ->
        Process.demonitor(monitor, [:flush])
        %{state | publishers: publishers}
    end
  end

  defp key(ticket), do: {ticket.slot, ticket.generation}
  defp failure(kind), do: {:error, %Error{kind: kind, phase: :wait, certainty: :unknown}}
end
