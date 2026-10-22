defmodule LibTmux.Control.Records do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Admission
  alias LibTmux.Operation.Lifecycle

  @enforce_keys [:table, :pool]
  defstruct @enforce_keys

  def new(%Admission{} = pool) do
    case Admission.entries(pool) do
      {:ok, _entries} -> :ok
      _ -> raise ArgumentError, "records require the current admission owner"
    end

    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    records = %__MODULE__{table: table, pool: pool}
    :ets.insert(table, {:context, records})
    :ets.insert(table, for(slot <- 1..pool.capacity, do: {slot, nil}))
    records
  end

  def validate(records), do: with_table(records, fn -> Admission.validate(records.pool) end)

  def fetch(records, %Admission.Lease{} = lease) do
    with_table(records, fn ->
      with {:ok, _state} <- current(records, lease) do
        result =
          case :ets.lookup(records.table, lease.slot) do
            [{_slot, %{lease: stored} = record}] when stored === lease -> {:ok, record}
            _ -> :pending
          end

        # Forget releases admission before clearing its old record.
        with {:ok, _state} <- current(records, lease), do: result
      end
    end)
  end

  defp current(records, lease) do
    case Admission.state(records.pool, lease) do
      {:error, %Error{kind: :stale_lease}} -> rejected(:stale_operation)
      {:error, %Error{kind: :connection_lost}} -> rejected(:connection_lost)
      other -> other
    end
  end

  # Only a dead destination proves its final persisted record cannot advance.
  # Router must store its first record and :writing phase before every send.
  def finalize(records, epoch, destination) when is_reference(epoch) and is_pid(destination),
    do: finalize(records, [{epoch, destination}])

  def finalize(records, destinations) when is_list(destinations) do
    owned(records, fn ->
      cond do
        destinations == [] ->
          {:ok, 0}

        Enum.any?(destinations, fn {_epoch, destination} -> Process.alive?(destination) end) ->
          rejected(:live_destination)

        true ->
          destinations = MapSet.new(destinations)

          with {:ok, entries} <- Admission.entries(records.pool) do
            count =
              Enum.reduce(entries, 0, fn {_state, lease}, count ->
                if MapSet.member?(destinations, {lease.epoch, lease.destination}) do
                  record =
                    case :ets.lookup(records.table, lease.slot) do
                      [{_slot, %{lease: stored} = record}] when stored === lease -> record
                      _ -> unwritten(lease)
                    end

                  {:ok, life, _actions} =
                    Lifecycle.step(record.life, {:epoch_closed, lease.epoch})

                  :ets.insert(records.table, {lease.slot, %{record | life: life}})
                  count + 1
                else
                  count
                end
              end)

            {:ok, count}
          end
      end
    end)
  end

  def forget(records, %Admission.Lease{} = lease) do
    owned(records, fn ->
      case fetch(records, lease) do
        {:ok, %{life: life} = record} ->
          if Lifecycle.wire_retired?(life) do
            with :ok <- Admission.release(records.pool, lease) do
              # A replacement can already have published its new record.
              pattern =
                {{lease.slot, :"$1"}, [{:"=:=", :"$1", {:const, record}}],
                 [{:const, {lease.slot, nil}}]}

              :ets.select_replace(records.table, [pattern])
              :ok
            end
          else
            rejected(:wire_active)
          end

        :pending ->
          rejected(:wire_active)

        error ->
          error
      end
    end)
  end

  defp unwritten(lease) do
    token = make_ref()
    life = Lifecycle.new(lease.epoch, token, %Deadline{expires_at: lease.expires_at}, lease.bytes)
    %{lease: lease, token: token, life: life, reply: nil}
  end

  defp owned(records, action) do
    with_table(records, fn ->
      if self() == records.pool.owner, do: action.(), else: rejected(:wrong_owner)
    end)
  end

  defp with_table(records, action) do
    case :ets.info(records.table, :owner) do
      :undefined ->
        rejected(:connection_lost)

      owner ->
        case :ets.lookup(records.table, :context) do
          [{:context, ^records}] when owner == records.pool.owner -> action.()
          _ -> rejected(:wrong_records)
        end
    end
  rescue
    error in ArgumentError ->
      if :ets.info(records.table) == :undefined,
        do: rejected(:connection_lost),
        else: reraise(error, __STACKTRACE__)
  end

  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :operation, certainty: :unknown}}
end
