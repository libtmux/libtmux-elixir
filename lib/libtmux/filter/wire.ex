defmodule LibTmux.Filter.Wire do
  @moduledoc false
  alias LibTmux.{Error, Filter, Schema, Wire}

  @entities %{
    "session" => :session,
    "window" => :window,
    "windowLink" => :window_link,
    "pane" => :pane,
    "client" => :client
  }
  @booleans %{"AND" => :and, "OR" => :or, "NOT" => :not}
  @operators %{
    "equals" => :equals,
    "not" => :not,
    "in" => :in,
    "notIn" => :not_in,
    "lt" => :lt,
    "lte" => :lte,
    "gt" => :gt,
    "gte" => :gte,
    "contains" => :contains,
    "startsWith" => :starts_with,
    "endsWith" => :ends_with,
    "some" => :some,
    "every" => :every,
    "none" => :none,
    "count" => :count,
    "is" => :is,
    "isNot" => :is_not
  }

  def decode_json(entity, binary, options) do
    with {:ok, payload} <- Wire.decode(binary, options), do: decode(entity, payload, options)
  end

  def decode(entity, payload, options) do
    entity = Schema.entity(entity)

    with {:ok, _} <- Wire.validate(payload, options) do
      try do
        unless is_map(payload) and Enum.sort(Map.keys(payload)) == ["entity", "version", "where"],
          do: invalid([], :invalid_envelope)

        unless payload["version"] === 1, do: invalid(["version"], :unsupported_version)
        unless @entities[payload["entity"]] == entity, do: invalid(["entity"], :entity_mismatch)
        criteria = criteria(payload["where"], entity, ["where"])

        case Filter.new(entity, criteria, options) do
          {:ok, filter} -> {:ok, filter}
          {:error, error} -> {:error, %{error | path: ["where" | path(error.path, entity)]}}
        end
      catch
        %Error{} = error -> {:error, error}
      end
    end
  end

  def encode(filter) do
    %{
      "version" => 1,
      "entity" => wire_name(@entities, filter.entity),
      "where" => expression(filter.tree, filter.entity)
    }
  end

  defp criteria(value, entity, path) when is_map(value) do
    fields = Map.new(Schema.fields(entity), fn {name, metadata} -> {metadata.wire, name} end)

    relations =
      Map.new(Schema.relations(entity), fn {name, target} ->
        {Schema.relation_wire(name), {name, target}}
      end)

    Map.new(value, fn {key, value} ->
      location = path ++ [key]

      cond do
        boolean = @booleans[key] ->
          child =
            if boolean == :not do
              criteria(value, entity, location)
            else
              unless is_list(value), do: invalid(location, :expected_list)

              value
              |> Enum.with_index()
              |> Enum.map(fn {child, index} -> criteria(child, entity, location ++ [index]) end)
            end

          {boolean, child}

        name = fields[key] ->
          {name, scalar(value, Schema.field(entity, name), location)}

        relation = relations[key] ->
          {name, {cardinality, target}} = relation
          unless is_map(value), do: invalid(location, :expected_object)

          operators =
            Map.new(value, fn {op, child} ->
              local = @operators[op]

              operand =
                cond do
                  cardinality == :many and local == :count ->
                    scalar(child, %{type: :integer}, location ++ [op])

                  cardinality == :many and local in [:some, :every, :none] ->
                    criteria(child, target, location ++ [op])

                  cardinality == :one and local in [:is, :is_not] and is_nil(child) ->
                    nil

                  cardinality == :one and local in [:is, :is_not] ->
                    criteria(child, target, location ++ [op])

                  true ->
                    invalid(location ++ [op], :unsupported_operator)
                end

              {local, operand}
            end)

          {name, operators}

        true ->
          invalid(location, :unknown_field)
      end
    end)
  end

  defp criteria(_value, _entity, path), do: invalid(path, :expected_object)

  defp scalar(value, metadata, path) when is_map(value) do
    Map.new(value, fn {op, operand} ->
      local = @operators[op]

      unless local in [
               :equals,
               :not,
               :in,
               :not_in,
               :lt,
               :lte,
               :gt,
               :gte,
               :contains,
               :starts_with,
               :ends_with
             ],
             do: invalid(path ++ [op], :unsupported_operator)

      operand =
        if local in [:in, :not_in] and is_list(operand),
          do: Enum.map(operand, &literal(&1, metadata)),
          else: literal(operand, metadata)

      {local, operand}
    end)
  end

  defp scalar(value, metadata, _path), do: literal(value, metadata)

  defp literal([session, index, window], %{type: {:id, :window_link}}),
    do: {session, index, window}

  defp literal(value, _metadata), do: value

  defp expression({:and, children}, entity) do
    parts = Enum.map(children, &expression(&1, entity))
    keys = Enum.flat_map(parts, &Map.keys/1)

    if length(keys) == MapSet.size(MapSet.new(keys)),
      do: Enum.reduce(parts, %{}, &Map.merge/2),
      else: %{"AND" => parts}
  end

  defp expression({:or, children}, entity),
    do: %{"OR" => Enum.map(children, &expression(&1, entity))}

  defp expression({:not, child}, entity), do: %{"NOT" => expression(child, entity)}

  defp expression({:field, field, :equals, value}, entity),
    do: %{Schema.field(entity, field).wire => value(value)}

  defp expression({:field, field, op, operand}, entity),
    do: %{Schema.field(entity, field).wire => %{wire_name(@operators, op) => value(operand)}}

  defp expression({:count, relation, operators}, _entity),
    do: %{
      Schema.relation_wire(relation) => %{
        "count" => Map.new(operators, fn {op, value} -> {wire_name(@operators, op), value} end)
      }
    }

  defp expression({:relation, relation, op, child}, entity) do
    {_cardinality, target} = Schema.relations(entity)[relation]

    %{
      Schema.relation_wire(relation) => %{
        wire_name(@operators, op) => if(is_nil(child), do: nil, else: expression(child, target))
      }
    }
  end

  defp value(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(value), do: value

  defp path([], _entity), do: []
  defp path([index | rest], entity) when is_integer(index), do: [index | path(rest, entity)]

  defp path([key | rest], entity) when key in [:and, :or, :not],
    do: [wire_name(@booleans, key) | path(rest, entity)]

  defp path([key | rest], entity) do
    cond do
      field = Schema.field(entity, key) ->
        [
          field.wire
          | Enum.map(rest, fn op -> if is_integer(op), do: op, else: wire_name(@operators, op) end)
        ]

      relation = Schema.relations(entity)[key] ->
        {_cardinality, target} = relation

        case rest do
          [:count | operators] ->
            [
              Schema.relation_wire(key),
              "count"
              | Enum.map(operators, fn op ->
                  if is_integer(op), do: op, else: wire_name(@operators, op)
                end)
            ]

          [operator | child] ->
            [Schema.relation_wire(key), wire_name(@operators, operator) | path(child, target)]

          [] ->
            [Schema.relation_wire(key)]
        end

      true ->
        [key | rest]
    end
  end

  defp wire_name(table, value),
    do: Enum.find_value(table, fn {wire, local} -> if local == value, do: wire end)

  defp invalid(path, code),
    do:
      throw(%Error{
        kind: :invalid_filter,
        certainty: :no_write,
        path: path,
        details: %{code: code}
      })
end
