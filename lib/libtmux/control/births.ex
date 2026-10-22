defmodule LibTmux.Control.Births do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Lifetime

  @enforce_keys [:table, :owner, :lifetime, :generation, :epoch, :deadline]
  defstruct @enforce_keys
  @roles [:epoch_supervisor, :router, :guardian]

  def new(lifetime, generation, epoch, %Deadline{} = deadline) do
    unless is_reference(epoch) and node(epoch) == node() and is_integer(generation) and
             generation > 0 and is_integer(deadline.expires_at) and
             deadline.expires_at in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
             Lifetime.status(lifetime) == %{generation: generation, phase: :starting},
           do: raise(ArgumentError, "startup registration requires the reserved starting epoch")

    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

    births = %__MODULE__{
      table: table,
      owner: self(),
      lifetime: lifetime,
      generation: generation,
      epoch: epoch,
      deadline: deadline
    }

    :ets.insert(table, [
      {:context, births},
      {:state, %{gate: :open, roles: Map.new(@roles, &{&1, nil})}}
    ])

    births
  end

  def register(births, role, options \\ []) do
    unless role in @roles, do: raise(ArgumentError, "invalid fixed startup role")
    with_table(births, fn -> register(births, role, options, 5) end)
  end

  def snapshot(births) do
    with_table(births, fn ->
      [{:state, state}] = :ets.lookup(births.table, :state)
      {:ok, state}
    end)
  end

  def enter(options, role) when role in [:router, :guardian] do
    case Keyword.get(options, :births) do
      nil ->
        :ok

      %__MODULE__{} = births ->
        common =
          Keyword.fetch!(options, :manager) == births.owner and
            Keyword.fetch!(options, :epoch) == births.epoch and
            Keyword.fetch!(options, :deadline) === births.deadline

        identity =
          Keyword.fetch!(options, :lifetime) === births.lifetime and
            Keyword.fetch!(options, :generation) === births.generation

        if common and identity, do: register(births, role), else: rejected(:wrong_births)
    end
  end

  # Close and capture share one CAS; a birth is either captured or rejected.
  # This closes registration only, not the Lifetime latch or native resources.
  def close(births) do
    with_table(births, fn ->
      if self() == births.owner, do: close(births, 5), else: rejected(:wrong_owner)
    end)
  end

  defp register(_births, _role, _options, 0), do: rejected(:startup_contention)

  defp register(births, role, options, attempts) do
    [{:state, current}] = :ets.lookup(births.table, :state)

    cond do
      current.gate == :closed ->
        rejected(:startup_closed)

      Deadline.remaining(births.deadline, options) == 0 ->
        rejected(:timeout)

      Lifetime.status(births.lifetime) != %{generation: births.generation, phase: :starting} ->
        rejected(:stale_epoch)

      not Process.alive?(births.owner) ->
        rejected(:connection_lost)

      current.roles[role] == self() ->
        :ok

      not is_nil(current.roles[role]) ->
        rejected(:role_taken)

      true ->
        next = %{current | roles: Map.put(current.roles, role, self())}

        if replace(births, current, next),
          do: :ok,
          else: register(births, role, options, attempts - 1)
    end
  end

  defp close(_births, 0), do: rejected(:startup_contention)

  defp close(births, attempts) do
    [{:state, current}] = :ets.lookup(births.table, :state)

    if current.gate == :closed or replace(births, current, %{current | gate: :closed}),
      do: {:ok, current.roles},
      else: close(births, attempts - 1)
  end

  defp replace(births, current, next) do
    pattern = {{:state, :"$1"}, [{:"=:=", :"$1", {:const, current}}], [{:const, {:state, next}}]}
    :ets.select_replace(births.table, [pattern]) == 1
  end

  defp with_table(births, action) do
    case :ets.info(births.table, :owner) do
      :undefined ->
        rejected(:connection_lost)

      owner ->
        case :ets.lookup(births.table, :context) do
          [{:context, ^births}] when owner == births.owner -> action.()
          _ -> rejected(:wrong_births)
        end
    end
  rescue
    error in ArgumentError ->
      if :ets.info(births.table) == :undefined,
        do: rejected(:connection_lost),
        else: reraise(error, __STACKTRACE__)
  end

  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :connect, certainty: :no_write}}
end
