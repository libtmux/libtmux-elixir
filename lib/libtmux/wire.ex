defmodule LibTmux.Wire do
  @moduledoc """
  Bounded JSON decoding with duplicate keys preserved until validation.

  Uses the built-in JSON decoder callbacks. Object keys stay strings; no
  atoms are created. Byte, nesting, node, array and string ceilings apply
  before conversion to public maps. Parsing failures retain root paths and
  offsets where supplied; duplicate-key failures identify the object path.
  Depth starts at zero for the root value and increases for every object
  member or array element; the maximum is inclusive for maps and JSON alike.
  """

  alias LibTmux.{Error, Filter}

  @typedoc "A JSON value with string-keyed objects; invalid external terms return a validation error."
  @type value :: nil | boolean() | integer() | float() | String.t() | [value()] | object()
  @typedoc "A JSON object whose keys remain strings; validation never creates atoms from external names."
  @type object :: %{optional(String.t()) => value()}

  @doc """
  Decodes one complete bounded JSON value, rejecting duplicate keys and trailing data.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec decode(binary(), [Filter.limit_option()]) :: {:ok, value()} | {:error, Error.t()}
  def decode(binary, options \\ []) when is_binary(binary) do
    limits = Filter.limits(options)

    try do
      if byte_size(binary) > limits.max_bytes, do: fail(:resource_limit, [], :bytes)

      start = fn old ->
        if old.depth > limits.max_depth, do: fail(:resource_limit, [], :depth)
        %{depth: old.depth + 1, nodes: old.nodes, values: [], count: 0}
      end

      push = fn value, acc, maximum ->
        if acc.count >= maximum, do: fail(:resource_limit, [], :list)
        if acc.nodes >= limits.max_nodes, do: fail(:resource_limit, [], :nodes)
        %{acc | values: [value | acc.values], count: acc.count + 1, nodes: acc.nodes + 1}
      end

      decoders = [
        array_start: start,
        object_start: start,
        array_push: fn value, acc -> push.(value, acc, limits.max_list) end,
        object_push: fn key, value, acc -> push.({key, value}, acc, 256) end,
        array_finish: fn acc, old -> {Enum.reverse(acc.values), %{old | nodes: acc.nodes}} end,
        object_finish: fn acc, old ->
          {{:json_object, Enum.reverse(acc.values)}, %{old | nodes: acc.nodes}}
        end,
        string: fn value ->
          if byte_size(value) > limits.max_string_bytes,
            do: fail(:resource_limit, [], :string_bytes)

          value
        end,
        integer: fn value ->
          if byte_size(value) > 20, do: fail(:resource_limit, [], :number_bytes)
          String.to_integer(value)
        end,
        float: fn value ->
          if byte_size(value) > 64, do: fail(:resource_limit, [], :number_bytes)
          String.to_float(value)
        end
      ]

      case JSON.decode(binary, %{depth: 0, nodes: 1}, decoders) do
        {value, _acc, ""} -> validate(objects(value, []), options)
        {_value, _acc, _rest} -> fail(:invalid_json, [], :trailing_data)
        {:error, reason} -> fail(:invalid_json, [], :syntax, %{reason: reason})
      end
    rescue
      ArgumentError ->
        {:error,
         %Error{
           kind: :invalid_json,
           phase: :parse,
           certainty: :no_write,
           details: %{code: :invalid_number}
         }}
    catch
      %Error{} = error -> {:error, error}
    end
  end

  @doc """
  Validates already-decoded JSON data and its complete encoded byte size.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec validate(term(), [Filter.limit_option()]) :: {:ok, value()} | {:error, Error.t()}
  def validate(value, options \\ []) do
    limits = Filter.limits(options)

    try do
      walk(value, [], 0, %{nodes: 0, bytes: 0, limits: limits})
      {:ok, value}
    catch
      %Error{} = error -> {:error, error}
    end
  end

  defp objects({:json_object, pairs}, path) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      if Map.has_key?(acc, key), do: fail(:invalid_json, path ++ [key], :duplicate_key)
      Map.put(acc, key, objects(value, path ++ [key]))
    end)
  end

  defp objects(values, path) when is_list(values),
    do:
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> objects(value, path ++ [index]) end)

  defp objects(value, _path), do: value

  defp walk(value, path, depth, state) do
    if depth > state.limits.max_depth, do: fail(:resource_limit, path, :depth)
    if state.nodes >= state.limits.max_nodes, do: fail(:resource_limit, path, :nodes)
    state = %{state | nodes: state.nodes + 1}

    cond do
      is_map(value) and not is_struct(value) ->
        if map_size(value) > 256, do: fail(:resource_limit, path, :object_members)
        state = charge(state, 2 + max(map_size(value) - 1, 0), path)

        Enum.reduce(value, state, fn {key, child}, state ->
          unless is_binary(key), do: fail(:invalid_json, path, :string_keys_required)
          state = charge_string(state, key, path ++ [key]) |> charge(1, path)
          walk(child, path ++ [key], depth + 1, state)
        end)

      is_list(value) ->
        if length(value) > state.limits.max_list, do: fail(:resource_limit, path, :list)
        state = charge(state, 2 + max(length(value) - 1, 0), path)

        value
        |> Enum.with_index()
        |> Enum.reduce(state, fn {child, index}, state ->
          walk(child, path ++ [index], depth + 1, state)
        end)

      is_binary(value) ->
        charge_string(state, value, path)

      is_integer(value) and value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 ->
        charge(state, byte_size(Integer.to_string(value)), path)

      is_float(value) ->
        charge(state, byte_size(JSON.encode!(value)), path)

      value in [true, false, nil] ->
        charge(state, byte_size(JSON.encode!(value)), path)

      true ->
        fail(:invalid_json, path, :unsupported_value)
    end
  end

  defp charge_string(state, value, path) do
    unless String.valid?(value), do: fail(:invalid_json, path, :utf8)

    if byte_size(value) > state.limits.max_string_bytes,
      do: fail(:resource_limit, path, :string_bytes)

    charge(state, IO.iodata_length(JSON.encode_to_iodata!(value)), path)
  end

  defp charge(state, bytes, path) do
    if state.bytes + bytes > state.limits.max_bytes, do: fail(:resource_limit, path, :bytes)
    %{state | bytes: state.bytes + bytes}
  end

  defp fail(kind, path, code, details \\ %{}),
    do:
      throw(%Error{
        kind: kind,
        phase: :parse,
        certainty: :no_write,
        path: path,
        details: Map.put(details, :code, code)
      })
end
