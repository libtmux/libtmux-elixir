defmodule LibTmux.Control.OwnedTerm do
  @moduledoc false
  @max_integer 340_282_366_920_938_463_463_374_607_431_768_211_455

  # The caller supplies only references to separately bounded known resources.
  def copy(value, max_bytes, references \\ [])
      when is_integer(max_bytes) and max_bytes in 1..131_072 and is_list(references) do
    references = Enum.take(references, 33)

    unless length(references) <= 32 and Enum.all?(references, &is_reference/1),
      do: raise(ArgumentError, "copy requires at most 32 known context references")

    state = %{bytes: max_bytes - 1, nodes: 8192, references: MapSet.new(references)}

    case walk(value, 0, state) do
      {:ok, copy, _remaining} -> {:ok, copy}
      error -> error
    end
  end

  defp walk(_value, depth, _state) when depth > 64, do: {:error, :resource_limit}

  defp walk(value, _depth, state) when is_binary(value) do
    with {:ok, state} <- charge(state, byte_size(value) + 5),
         do: {:ok, :binary.copy(value), state}
  end

  defp walk(value, _depth, state)
       when is_atom(value) or is_float(value) or is_pid(value) or
              (is_integer(value) and value >= -@max_integer and value <= @max_integer) do
    with {:ok, state} <- charge(state, :erlang.external_size(value) - 1),
         do: {:ok, value, state}
  end

  defp walk(value, _depth, state) when is_reference(value) do
    if MapSet.member?(state.references, value) do
      with {:ok, state} <- charge(state, :erlang.external_size(value) - 1),
           do: {:ok, value, state}
    else
      {:error, :invalid_outcome}
    end
  end

  defp walk([], _depth, state) do
    with {:ok, state} <- charge(state, 1), do: {:ok, [], state}
  end

  defp walk([head | tail], depth, state) do
    with {:ok, state} <- charge(state, 5),
         {:ok, head, state} <- walk(head, depth + 1, state),
         {:ok, tail, state} <- walk(tail, depth, state),
         do: {:ok, [head | tail], state}
  end

  defp walk(value, depth, state) when is_tuple(value) do
    with {:ok, state} <- charge(state, 5) do
      if tuple_size(value) <= state.nodes,
        do: tuple(value, 0, [], depth, state),
        else: {:error, :resource_limit}
    end
  end

  defp walk(value, depth, state) when is_map(value) do
    with {:ok, state} <- charge(state, 5) do
      if map_size(value) <= div(state.nodes, 2),
        do: map(:maps.iterator(value), %{}, depth, state),
        else: {:error, :resource_limit}
    end
  end

  defp walk(_value, _depth, _state), do: {:error, :invalid_outcome}

  defp tuple(value, index, acc, _depth, state) when index == tuple_size(value),
    do: {:ok, acc |> Enum.reverse() |> List.to_tuple(), state}

  defp tuple(value, index, acc, depth, state) do
    with {:ok, item, state} <- walk(elem(value, index), depth + 1, state),
         do: tuple(value, index + 1, [item | acc], depth, state)
  end

  defp map(iterator, acc, depth, state) do
    case :maps.next(iterator) do
      :none ->
        {:ok, acc, state}

      {key, value, next} ->
        with {:ok, key, state} <- walk(key, depth + 1, state),
             {:ok, value, state} <- walk(value, depth + 1, state),
             do: map(next, Map.put(acc, key, value), depth, state)
    end
  end

  defp charge(%{bytes: bytes, nodes: nodes} = state, size)
       when size <= bytes and nodes > 0,
       do: {:ok, %{state | bytes: bytes - size, nodes: nodes - 1}}

  defp charge(_state, _size), do: {:error, :resource_limit}
end
