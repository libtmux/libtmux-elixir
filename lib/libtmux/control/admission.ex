defmodule LibTmux.Control.Admission do
  @moduledoc false

  alias LibTmux.{Deadline, Error}

  defmodule Lease do
    @moduledoc false
    @enforce_keys [
      :table,
      :slot,
      :generation,
      :epoch,
      :destination,
      :publisher,
      :expires_at,
      :bytes
    ]
    defstruct @enforce_keys ++ [mode: :retained]
    @opaque t :: %__MODULE__{}
  end

  @enforce_keys [:table, :owner, :capacity, :max_bytes]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{}
  @max_generation 18_446_744_073_709_551_615

  # The Manager owns fixed records; trusted producers atomically claim before sending.
  # Leases contain bounded metadata, never command payloads or reply buffers.
  def new(capacity, options \\ []) do
    options = Keyword.validate!(options, max_bytes: 65_536)
    max_bytes = options[:max_bytes]

    unless is_integer(capacity) and capacity in 1..256 and
             is_integer(max_bytes) and max_bytes in 1..65_536,
           do: raise(ArgumentError, "admission requires 1..256 slots and 1..65536 encoded bytes")

    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    true = :ets.insert(table, for(slot <- 1..capacity, do: free(slot, 0)))
    pool = %__MODULE__{table: table, owner: self(), capacity: capacity, max_bytes: max_bytes}
    true = :ets.insert(table, {:context, pool})
    pool
  end

  def validate(pool), do: with_table(pool, fn -> :ok end)

  @spec claim(t(), reference(), pid(), Deadline.t(), pos_integer(), keyword()) ::
          {:ok, Lease.t()} | {:error, Error.t()}
  def claim(pool, epoch, destination, deadline, bytes, options \\ [])

  def claim(
        %__MODULE__{} = pool,
        epoch,
        destination,
        %Deadline{expires_at: expires_at} = deadline,
        bytes,
        options
      )
      when is_reference(epoch) and node(epoch) == node() and is_pid(destination) and
             node(destination) == node() and is_integer(expires_at) and
             expires_at in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
             is_integer(bytes) and bytes > 0 do
    options = Keyword.validate!(options, [:now, mode: :retained])

    unless options[:mode] in [:retained, :managed],
      do: raise(ArgumentError, "invalid admission ownership mode")

    with_table(pool, fn ->
      cond do
        bytes > pool.max_bytes ->
          rejected(:resource_limit)

        Deadline.remaining(deadline, options) == 0 ->
          rejected(:timeout)

        not Process.alive?(destination) ->
          rejected(:stale_epoch)

        true ->
          reserve(pool, epoch, destination, deadline, bytes, options[:mode])
      end
    end)
  end

  def claim(_pool, _epoch, _destination, _deadline, _bytes, _options),
    do:
      raise(
        ArgumentError,
        "admission requires a local destination/epoch, signed 64-bit deadline and byte count"
      )

  # Consuming proves that this publication reached its fixed destination.
  def consume(%__MODULE__{} = pool, %Lease{} = lease, encoded_bytes)
      when is_integer(encoded_bytes) and encoded_bytes > 0 do
    with_table(pool, fn ->
      cond do
        lease.table != pool.table ->
          rejected(:stale_lease)

        self() != lease.destination ->
          rejected(:wrong_destination)

        encoded_bytes > lease.bytes or encoded_bytes > pool.max_bytes ->
          rejected(:resource_limit)

        true ->
          reserved = row(lease, :reserved)

          # Lease fields remain data; only an equal stored row becomes a match pattern.
          case :ets.lookup(pool.table, lease.slot) do
            [entry] when entry === reserved -> replace(pool, entry, put_elem(entry, 2, :consumed))
            _ -> rejected(:stale_lease)
          end
      end
    end)
  end

  # The final writer rechecks the exact consumed generation immediately before I/O.
  def verify_consumed(%__MODULE__{} = pool, %Lease{} = lease) do
    with_table(pool, fn ->
      expected = row(lease, :consumed)

      case :ets.lookup(pool.table, lease.slot) do
        [entry] when lease.table == pool.table and entry === expected -> :ok
        _ -> rejected(:stale_lease)
      end
    end)
  end

  def state(%__MODULE__{} = pool, %Lease{} = lease) do
    with_table(pool, fn ->
      reserved = row(lease, :reserved)
      consumed = row(lease, :consumed)

      case :ets.lookup(pool.table, lease.slot) do
        [entry] when lease.table == pool.table and entry === reserved -> {:ok, :reserved}
        [entry] when lease.table == pool.table and entry === consumed -> {:ok, :consumed}
        _ -> rejected(:stale_lease)
      end
    end)
  end

  def entries(%__MODULE__{} = pool) do
    owned(pool, fn ->
      entries =
        for {_slot, _generation, state, _epoch, _destination, _publisher, _expires, _bytes, _mode} =
              entry <- :ets.tab2list(pool.table),
            state in [:reserved, :consumed],
            do: {state, lease(pool, entry)}

      {:ok, Enum.sort_by(entries, fn {_state, lease} -> lease.slot end)}
    end)
  end

  # Only the Manager releases consumed capacity after logical/wire/retention rules.
  # An expired or dead publisher does not prove that its publication is absent.
  def release(%__MODULE__{} = pool, %Lease{} = lease) do
    owned(pool, fn ->
      if lease.table != pool.table do
        rejected(:stale_lease)
      else
        reserved = row(lease, :reserved)
        consumed = row(lease, :consumed)

        case :ets.lookup(pool.table, lease.slot) do
          [^reserved] ->
            if Process.alive?(lease.destination),
              do: rejected(:unconsumed_lease),
              else: replace(pool, reserved, free(lease.slot, lease.generation))

          [^consumed] ->
            replace(pool, consumed, free(lease.slot, lease.generation))

          _ ->
            rejected(:stale_lease)
        end
      end
    end)
  end

  def unpublished_expired(%__MODULE__{} = pool, options \\ []) do
    options = Keyword.validate!(options, [:now])
    now = Keyword.get_lazy(options, :now, fn -> System.monotonic_time(:millisecond) end)
    unless is_integer(now), do: raise(ArgumentError, "now requires monotonic milliseconds")

    owned(pool, fn ->
      leases =
        for {_slot, _generation, :reserved, _epoch, _destination, _publisher, expires, _bytes,
             _mode} =
              entry <- :ets.tab2list(pool.table),
            expires <= now,
            do: lease(pool, entry)

      {:ok, Enum.sort_by(leases, & &1.slot)}
    end)
  end

  # Dead destination PID is a mailbox boundary, not proof of native retirement.
  def retire_destination(%__MODULE__{} = pool, epoch, destination)
      when is_reference(epoch) and is_pid(destination) and node(destination) == node() do
    owned(pool, fn ->
      if Process.alive?(destination) do
        rejected(:live_destination)
      else
        count =
          for {slot, generation, :reserved, ^epoch, ^destination, _publisher, _expires, _bytes,
               _mode} =
                entry <- :ets.tab2list(pool.table),
              reduce: 0 do
            count ->
              count +
                :ets.select_replace(pool.table, [{entry, [], [{:const, free(slot, generation)}]}])
          end

        {:ok, count}
      end
    end)
  end

  defp reserve(pool, epoch, destination, deadline, bytes, mode) do
    Enum.reduce_while(1..pool.capacity, rejected(:resource_limit), fn slot, full ->
      case :ets.lookup(pool.table, slot) do
        [{^slot, generation, :free, nil, nil, nil, nil, nil, nil} = entry]
        when generation < @max_generation ->
          claimed =
            {slot, generation + 1, :reserved, epoch, destination, self(), deadline.expires_at,
             bytes, mode}

          if :ets.select_replace(pool.table, [{entry, [], [{:const, claimed}]}]) == 1,
            do: {:halt, {:ok, lease(pool, claimed)}},
            else: {:cont, full}

        _ ->
          {:cont, full}
      end
    end)
  end

  defp lease(
         pool,
         {slot, generation, _state, epoch, destination, publisher, expires_at, bytes, mode}
       ),
       do: %Lease{
         table: pool.table,
         slot: slot,
         generation: generation,
         epoch: epoch,
         destination: destination,
         publisher: publisher,
         expires_at: expires_at,
         bytes: bytes,
         mode: mode
       }

  defp row(lease, state),
    do:
      {lease.slot, lease.generation, state, lease.epoch, lease.destination, lease.publisher,
       lease.expires_at, lease.bytes, lease.mode}

  defp free(slot, generation), do: {slot, generation, :free, nil, nil, nil, nil, nil, nil}

  defp replace(pool, current, next) do
    if :ets.select_replace(pool.table, [{current, [], [{:const, next}]}]) == 1,
      do: :ok,
      else: rejected(:stale_lease)
  end

  defp owned(pool, operation),
    do:
      with_table(pool, fn ->
        if(self() == pool.owner, do: operation.(), else: rejected(:wrong_owner))
      end)

  defp with_table(pool, operation) do
    case :ets.info(pool.table, :owner) do
      :undefined ->
        rejected(:connection_lost)

      owner ->
        case :ets.lookup(pool.table, :context) do
          [{:context, ^pool}] when owner == pool.owner -> operation.()
          _ -> rejected(:wrong_pool)
        end
    end
  rescue
    error in ArgumentError ->
      if :ets.info(pool.table) == :undefined,
        do: rejected(:connection_lost),
        else: reraise(error, __STACKTRACE__)
  end

  defp rejected(kind),
    do: {:error, %Error{kind: kind, phase: :admission, certainty: :no_write}}
end
