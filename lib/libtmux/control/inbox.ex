defmodule LibTmux.Control.Inbox do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Admission.Lease
  alias LibTmux.Control.OwnedTerm
  alias LibTmux.Transport.Reply

  defmodule Ticket do
    @moduledoc false
    @enforce_keys [:table, :slot, :generation, :epoch, :expires_at, :caller, :reply, :token]
    defstruct @enforce_keys
  end

  @enforce_keys [:table, :owner, :capacity, :kinds, :wake, :receipts, :max_outcome_bytes]
  defstruct @enforce_keys
  @max_generation 18_446_744_073_709_551_615
  @max_wake 9_223_372_036_854_775_807

  def new(capacity, options) when is_integer(capacity) and capacity in 1..256 do
    options = Keyword.validate!(options, [:kinds, max_outcome_bytes: 65_536])
    kinds = Keyword.fetch!(options, :kinds)
    max_outcome_bytes = options[:max_outcome_bytes]

    unless is_integer(max_outcome_bytes) and max_outcome_bytes in 1024..131_072 and
             is_list(kinds) and length(kinds) in 1..3 and Enum.uniq(kinds) == kinds and
             Enum.all?(kinds, &(&1 in [:reconnect, :forget, :await, :collect, :connection])),
           do: raise(ArgumentError, "inbox requires fixed kinds and 1024..131072 outcome bytes")

    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    :ets.insert(table, for(slot <- 1..capacity, do: {slot, free(0)}))

    inbox = %__MODULE__{
      table: table,
      owner: self(),
      capacity: capacity,
      kinds: kinds,
      max_outcome_bytes: max_outcome_bytes,
      wake: :atomics.new(1, signed: false),
      receipts: :atomics.new(capacity, signed: false)
    }

    :ets.insert(table, {:context, inbox})
    inbox
  end

  # Publication is the CAS itself. A later wake contains no request or result.
  def publish(inbox, epoch, %Deadline{} = deadline, request, options \\ []) do
    unless local_ref?(epoch) and
             deadline.expires_at in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
             is_integer(deadline.expires_at) and valid_request?(inbox, request),
           do: raise(ArgumentError, "invalid bounded inbox metadata")

    cond do
      Deadline.remaining(deadline, options) == 0 ->
        rejected(:timeout)

      not Process.alive?(inbox.owner) ->
        rejected(:connection_lost)

      :erlang.external_size({epoch, deadline, request}) > 3072 ->
        rejected(:resource_limit)

      true ->
        with_table(inbox, fn ->
          reply = :erlang.alias()
          token = make_ref()

          try do
            result =
              Enum.reduce_while(1..inbox.capacity, rejected(:resource_limit), fn slot, full ->
                data = %{
                  state: :pending,
                  epoch: epoch,
                  expires_at: deadline.expires_at,
                  caller: self(),
                  reply: reply,
                  token: token,
                  request: request,
                  outcome: nil
                }

                case claim(inbox, slot, data, 2) do
                  {:ok, ticket} -> {:halt, {:ok, ticket}}
                  :full -> {:cont, full}
                end
              end)

            if match?({:error, _}, result), do: Reply.close(reply, token)
            result
          catch
            kind, reason ->
              Reply.close(reply, token)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end)
    end
  end

  def notify(inbox) do
    case reserve_wake(inbox) do
      {:ok, {owner, table, generation}} ->
        send(owner, {__MODULE__, :wake, table, generation})
        :ok

      :pending ->
        :ok

      error ->
        error
    end
  end

  def validate(inbox), do: with_table(inbox, fn -> :ok end)

  def reserve_wake(inbox) do
    with_table(inbox, fn ->
      word = :atomics.get(inbox.wake, 1)

      if rem(word, 2) == 1 or div(word, 2) == @max_wake do
        :pending
      else
        case :atomics.compare_exchange(inbox.wake, 1, word, word + 1) do
          :ok -> {:ok, {inbox.owner, inbox.table, div(word, 2)}}
          _lost -> :pending
        end
      end
    end)
  end

  # Sweeps never clear this word: a frozen sender still owns its one hint.
  def consume_wake(inbox, {owner, table, generation})
      when is_integer(generation) and generation >= 0 and generation < @max_wake do
    owned(inbox, fn ->
      if owner == inbox.owner and table == inbox.table and
           :atomics.compare_exchange(inbox.wake, 1, generation * 2 + 1, (generation + 1) * 2) ==
             :ok, do: :ok, else: rejected(:stale_hint)
    end)
  end

  def consume_wake(_inbox, _hint), do: rejected(:stale_hint)

  def take(inbox, options \\ []) do
    owned(inbox, fn ->
      work =
        Enum.flat_map(1..inbox.capacity, fn slot ->
          case start(inbox, slot, 2) do
            {:ok, ticket, data} ->
              cond do
                receiver_closed?(inbox, slot, data) ->
                  :ok =
                    complete(
                      inbox,
                      ticket,
                      {:error, failure(:cancelled, pending_certainty(data))},
                      2
                    )

                  []

                Deadline.remaining(%Deadline{expires_at: data.expires_at}, options) == 0 ->
                  :ok =
                    complete(
                      inbox,
                      ticket,
                      {:error, failure(:timeout, pending_certainty(data))},
                      2
                    )

                  []

                true ->
                  [{ticket, data.request}]
              end

            :skip ->
              []
          end
        end)

      {:ok, work}
    end)
  end

  def finish(inbox, %Ticket{} = ticket, outcome, options \\ []) do
    case prepare(inbox, ticket, outcome, options) do
      {:ok, copy} -> finish_prepared(inbox, ticket, copy, options)
      {:error, error} -> finish_prepared(inbox, ticket, {:error, error}, options)
    end
  end

  # Preparation detaches bounded result data without making the ticket readable.
  # A collector must release its exact retired record before publishing this copy.
  def prepare(inbox, %Ticket{} = ticket, outcome, options \\ []) do
    owned(inbox, fn ->
      with {:ok, %{state: :working} = data} <- fetch(inbox, ticket) do
        if Deadline.remaining(%Deadline{expires_at: data.expires_at}, options) == 0 do
          {:error, failure(:timeout, :unknown)}
        else
          references = [
            inbox.table,
            inbox.wake,
            inbox.receipts | Keyword.get(options, :references, [])
          ]

          case OwnedTerm.copy(outcome, inbox.max_outcome_bytes, references) do
            {:ok, copy} -> {:ok, copy}
            {:error, kind} -> {:error, failure(kind, known_certainty(outcome))}
          end
        end
      else
        {:ok, _data} -> rejected(:settled_ticket)
        error -> error
      end
    end)
  end

  def finish_prepared(inbox, %Ticket{} = ticket, outcome, options \\ []) do
    owned(inbox, fn ->
      with {:ok, data} <- fetch(inbox, ticket) do
        outcome =
          if Deadline.remaining(%Deadline{expires_at: data.expires_at}, options) == 0,
            do: {:error, failure(:timeout, :unknown)},
            else: outcome

        complete(inbox, ticket, outcome, 2)
      end
    end)
  end

  defp claim(_inbox, _slot, _data, 0), do: :full

  defp claim(inbox, slot, data, attempts) do
    case :ets.lookup(inbox.table, slot) do
      [{^slot, %{generation: generation} = current}] when generation < @max_generation ->
        reusable =
          current.state == :free or
            (current.state == :done and receiver_closed?(inbox, slot, current))

        if reusable do
          next = Map.put(data, :generation, generation + 1)

          case replace(inbox, slot, current, next) do
            :ok -> {:ok, ticket(inbox, slot, next)}
            _changed -> claim(inbox, slot, data, attempts - 1)
          end
        else
          :full
        end

      _ ->
        :full
    end
  end

  def result(inbox, %Ticket{} = ticket) do
    with_table(inbox, fn ->
      with {:ok, data} <- fetch(inbox, ticket),
           true <- self() == data.caller do
        if data.state == :done, do: {:ok, data.outcome}, else: :pending
      else
        false -> rejected(:wrong_receiver)
        error -> error
      end
    end)
  end

  def closed?(inbox, %Ticket{} = ticket) do
    owned(inbox, fn ->
      with {:ok, data} <- fetch(inbox, ticket),
           do: {:ok, receiver_closed?(inbox, ticket.slot, data)}
    end)
  end

  def close(inbox, %Ticket{} = ticket) do
    result =
      with_table(inbox, fn ->
        with {:ok, data} <- fetch(inbox, ticket),
             true <- self() == data.caller do
          Reply.close(data.reply, data.token)
          acknowledge(inbox, ticket)
        else
          false -> rejected(:wrong_receiver)
          error -> error
        end
      end)

    # A lost owner cannot verify a row, but the caller still owns its reply alias.
    if match?({:error, %Error{kind: :connection_lost}}, result) and self() == ticket.caller and
         local_ref?(ticket.reply) and local_ref?(ticket.token),
       do: Reply.close(ticket.reply, ticket.token)

    result
  end

  def reap(inbox) do
    owned(inbox, fn ->
      count =
        Enum.reduce(1..inbox.capacity, 0, fn slot, count ->
          case :ets.lookup(inbox.table, slot) do
            [{^slot, %{state: :done} = data}] ->
              if receiver_closed?(inbox, slot, data) do
                if replace(inbox, slot, data, free(data.generation)) == :ok,
                  do: count + 1,
                  else: count
              else
                count
              end

            _ ->
              count
          end
        end)

      {:ok, count}
    end)
  end

  defp start(_inbox, _slot, 0), do: :skip

  defp start(inbox, slot, attempts) do
    case :ets.lookup(inbox.table, slot) do
      [{^slot, %{state: :pending} = data}] ->
        next = %{data | state: :working}

        if replace(inbox, slot, data, next) == :ok,
          do: {:ok, ticket(inbox, slot, next), next},
          else: start(inbox, slot, attempts - 1)

      _ ->
        :skip
    end
  end

  defp complete(_inbox, _ticket, _outcome, 0), do: rejected(:stale_ticket)

  defp complete(inbox, ticket, outcome, attempts) do
    with {:ok, %{state: :working} = data} <- fetch(inbox, ticket) do
      next = %{data | state: :done, outcome: outcome}

      if replace(inbox, ticket.slot, data, next) == :ok do
        # Capture this recipient before capacity can ever be recycled.
        if not receiver_closed?(inbox, ticket.slot, next),
          do: send(next.reply, {next.token, :ready})

        :ok
      else
        complete(inbox, ticket, outcome, attempts - 1)
      end
    else
      {:ok, _data} -> rejected(:settled_ticket)
      error -> error
    end
  end

  # A delayed duplicate receipt must never overwrite a replacement's receipt.
  defp acknowledge(inbox, ticket) do
    current = :atomics.get(inbox.receipts, ticket.slot)

    if current >= ticket.generation do
      :ok
    else
      case :atomics.compare_exchange(inbox.receipts, ticket.slot, current, ticket.generation) do
        :ok -> :ok
        observed when observed >= ticket.generation -> :ok
        _changed -> acknowledge(inbox, ticket)
      end
    end
  end

  defp receiver_closed?(inbox, slot, data),
    do: :atomics.get(inbox.receipts, slot) >= data.generation or not Process.alive?(data.caller)

  defp fetch(inbox, ticket) do
    if ticket.table == inbox.table and is_integer(ticket.slot) and
         ticket.slot in 1..inbox.capacity do
      case :ets.lookup(inbox.table, ticket.slot) do
        [{_slot, %{state: state} = data}] when state != :free ->
          expected = ticket(inbox, ticket.slot, data)
          if expected === ticket, do: {:ok, data}, else: rejected(:stale_ticket)

        _ ->
          rejected(:stale_ticket)
      end
    else
      rejected(:stale_ticket)
    end
  end

  defp ticket(inbox, slot, data),
    do:
      struct!(
        Ticket,
        Map.take(data, [:generation, :epoch, :expires_at, :caller, :reply, :token])
        |> Map.merge(%{table: inbox.table, slot: slot})
      )

  # The match head is fixed; arbitrary nested metadata remains literal guard data.
  defp replace(inbox, slot, current, next) do
    pattern = {{slot, :"$1"}, [{:"=:=", :"$1", {:const, current}}], [{:const, {slot, next}}]}
    if :ets.select_replace(inbox.table, [pattern]) == 1, do: :ok, else: rejected(:stale_ticket)
  end

  defp free(generation), do: %{generation: generation, state: :free}

  defp valid_request?(inbox, {:reconnect, nil}), do: :reconnect in inbox.kinds

  defp valid_request?(inbox, {:connection, action}) when action in [:ready, :retired, :shutdown],
    do: :connection in inbox.kinds

  defp valid_request?(inbox, {kind, %Lease{} = lease}) when kind in [:forget, :await, :collect] do
    kind in inbox.kinds and local_ref?(lease.table) and local_ref?(lease.epoch) and
      is_integer(lease.slot) and lease.slot in 1..256 and is_integer(lease.generation) and
      lease.generation in 1..@max_generation and is_integer(lease.expires_at) and
      lease.expires_at in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
      is_integer(lease.bytes) and lease.bytes in 1..65_536 and
      lease.mode in [:retained, :managed] and
      is_pid(lease.destination) and node(lease.destination) == node() and
      is_pid(lease.publisher) and node(lease.publisher) == node()
  end

  defp valid_request?(_inbox, _request), do: false

  defp pending_certainty(%{request: {:await, _lease}}), do: :unknown
  defp pending_certainty(%{request: {:collect, _lease}}), do: :unknown
  defp pending_certainty(%{request: {:connection, _action}}), do: :unknown
  defp pending_certainty(_data), do: :no_write

  defp known_certainty({tag, %{certainty: certainty}})
       when tag in [:ok, :error] and certainty in [:no_write, :acknowledged, :observed, :unknown],
       do: certainty

  defp known_certainty(_outcome), do: :unknown
  defp local_ref?(value), do: is_reference(value) and node(value) == node()

  defp owned(inbox, action),
    do:
      with_table(inbox, fn ->
        if(self() == inbox.owner, do: action.(), else: rejected(:wrong_owner))
      end)

  defp with_table(inbox, action) do
    case :ets.info(inbox.table, :owner) do
      :undefined ->
        rejected(:connection_lost)

      owner ->
        case :ets.lookup(inbox.table, :context) do
          [{:context, ^inbox}] when owner == inbox.owner -> action.()
          _ -> rejected(:wrong_inbox)
        end
    end
  rescue
    error in ArgumentError ->
      if :ets.info(inbox.table) == :undefined,
        do: rejected(:connection_lost),
        else: reraise(error, __STACKTRACE__)
  end

  defp failure(kind, certainty), do: %Error{kind: kind, phase: :wait, certainty: certainty}
  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :admission, certainty: :no_write}}
end
