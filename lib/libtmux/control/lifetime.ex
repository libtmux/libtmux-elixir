defmodule LibTmux.Control.Lifetime do
  @moduledoc false

  alias LibTmux.Error

  # Create once before the connection child spec. Reuse it across restarts.
  # Only the Manager with complete native/subtree retirement proof calls retired/2.
  @enforce_keys [:word]
  defstruct [:word]
  @opaque t :: %__MODULE__{word: :atomics.atomics_ref()}
  @type token :: pos_integer()
  @max_generation 2_305_843_009_213_693_951
  @phases {:retired, :starting, :ready, :closing, :unknown}

  def new, do: %__MODULE__{word: :atomics.new(1, signed: false)}

  def abandon_initial(%__MODULE__{word: word}) do
    abandon_initial(word, :atomics.get(word, 1))
  end

  defp abandon_initial(word, current) do
    generation = div(current, 8)
    phase = rem(current, 8)

    cond do
      generation > 1 ->
        rejected(:stale_epoch)

      phase == 4 or current == 8 ->
        :ok

      current == 0 or (generation == 1 and phase in [1, 2, 3]) ->
        case :atomics.compare_exchange(word, 1, current, generation * 8 + 4) do
          :ok -> :ok
          observed -> abandon_initial(word, observed)
        end

      true ->
        rejected(:invalid_transition)
    end
  end

  @spec begin_epoch(t()) :: {:ok, token()} | {:error, Error.t()}
  def begin_epoch(%__MODULE__{word: word}) do
    current = :atomics.get(word, 1)
    generation = div(current, 8)

    cond do
      rem(current, 8) != 0 ->
        blocked(current)

      generation == @max_generation ->
        rejected(:resource_limit)

      true ->
        next = generation + 1

        case :atomics.compare_exchange(word, 1, current, next * 8 + 1) do
          :ok -> {:ok, next}
          observed -> blocked(observed)
        end
    end
  end

  def ready(lifetime, token), do: transition(lifetime, token, [1], 2)
  def revoke(lifetime, token), do: transition(lifetime, token, [1, 2], 3)
  def retired(lifetime, token), do: transition(lifetime, token, [3], 0)
  def abandon(lifetime, token), do: transition(lifetime, token, [1, 2, 3], 4)

  @spec allows_write?(t(), token()) :: boolean()
  # This observes the latch; only the epoch writer serializes writes and closure.
  def allows_write?(%__MODULE__{word: word}, token) when is_integer(token) and token > 0,
    do: :atomics.get(word, 1) == token * 8 + 2

  def allows_write?(%__MODULE__{}, _token), do: false

  def status(%__MODULE__{word: word}) do
    current = :atomics.get(word, 1)
    %{generation: div(current, 8), phase: elem(@phases, rem(current, 8))}
  end

  defp transition(%__MODULE__{word: word}, token, from, to)
       when is_integer(token) and token > 0 do
    current = :atomics.get(word, 1)
    advance(word, token, from, to, current)
  end

  defp transition(_lifetime, _token, _from, _to),
    do: raise(ArgumentError, "lifetime transition requires a positive epoch token")

  # Within a generation the allowed phases only advance. A lost starting CAS
  # must still close a concurrent ready phase without following a replacement.
  defp advance(word, token, from, to, current) do
    phase = rem(current, 8)

    cond do
      div(current, 8) != token ->
        rejected(:stale_epoch)

      phase == to ->
        :ok

      phase == 4 ->
        rejected(:cleanup_unknown)

      phase in from ->
        case :atomics.compare_exchange(word, 1, current, token * 8 + to) do
          :ok -> :ok
          observed -> advance(word, token, from, to, observed)
        end

      true ->
        rejected(:invalid_transition)
    end
  end

  defp blocked(current),
    do: rejected(if(rem(current, 8) == 4, do: :cleanup_unknown, else: :unretired_epoch))

  defp rejected(kind),
    do: {:error, %Error{kind: kind, phase: :admission, certainty: :no_write}}
end
