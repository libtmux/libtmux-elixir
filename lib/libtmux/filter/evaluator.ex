defmodule LibTmux.Filter.Evaluator do
  @moduledoc false
  alias LibTmux.{Error, Schema, Snapshot}

  def prepare(filter, %Snapshot{} = snapshot) do
    {predicate, relations} = compile(filter.tree, filter.entity, snapshot, %{})

    if map_size(relations) == 0 do
      fields = filter.tree |> scalar_fields() |> Enum.uniq()
      entity = filter.entity

      fn item ->
        Enum.each(fields, fn field ->
          case Map.fetch!(item, field) do
            state when state in [:unloaded, :unavailable] ->
              kind = if state == :unloaded, do: :field_not_loaded, else: :field_unavailable

              raise Error,
                kind: kind,
                phase: :evaluation,
                certainty: :no_write,
                path: [entity, field]

            _value ->
              :ok
          end
        end)

        predicate.(item)
      end
    else
      entity = filter.entity

      fn item ->
        case Snapshot.fetch(snapshot, entity, item.id) do
          {:ok, ^item} ->
            predicate.(item)

          _ ->
            raise Error,
              kind: :observation_mismatch,
              phase: :evaluation,
              certainty: :no_write,
              path: [entity, item.id]
        end
      end
    end
  end

  defp scalar_fields({:field, field, _op, _value}), do: [field]
  defp scalar_fields({:not, child}), do: scalar_fields(child)

  defp scalar_fields({boolean, children}) when boolean in [:and, :or],
    do: Enum.flat_map(children, &scalar_fields/1)

  defp compile({:and, children}, entity, snapshot, relations) do
    {predicates, relations} =
      Enum.map_reduce(children, relations, &compile(&1, entity, snapshot, &2))

    {fn item -> Enum.all?(predicates, & &1.(item)) end, relations}
  end

  defp compile({:or, children}, entity, snapshot, relations) do
    {predicates, relations} =
      Enum.map_reduce(children, relations, &compile(&1, entity, snapshot, &2))

    {fn item -> Enum.any?(predicates, & &1.(item)) end, relations}
  end

  defp compile({:not, child}, entity, snapshot, relations) do
    {predicate, relations} = compile(child, entity, snapshot, relations)
    {fn item -> not predicate.(item) end, relations}
  end

  defp compile({:field, field, op, value}, entity, snapshot, relations) do
    Snapshot.require_field!(snapshot, entity, field)
    predicate = scalar(op, value)
    {fn item -> predicate.(Map.fetch!(item, field)) end, relations}
  end

  defp compile({:count, relation, operators}, entity, snapshot, relations) do
    {related, relations} = related(snapshot, entity, relation, relations)
    predicates = Enum.map(operators, fn {op, value} -> scalar(op, value) end)

    {fn item ->
       count = length(related.(item.id))
       Enum.all?(predicates, & &1.(count))
     end, relations}
  end

  defp compile({:relation, relation, op, child}, entity, snapshot, relations) do
    {related, relations} = related(snapshot, entity, relation, relations)
    {_cardinality, target} = Schema.relations(entity)[relation]

    {predicate, relations} =
      if is_nil(child), do: {nil, relations}, else: compile(child, target, snapshot, relations)

    {fn item -> quantify(related.(item.id), op, predicate) end, relations}
  end

  defp related(snapshot, entity, relation, relations) do
    key = {entity, relation}

    case Map.fetch(relations, key) do
      {:ok, related} ->
        {related, relations}

      :error ->
        related = Snapshot.prepare_relation!(snapshot, entity, relation)
        {related, Map.put(relations, key, related)}
    end
  end

  defp quantify(items, :some, predicate), do: Enum.any?(items, predicate)
  defp quantify(items, :every, predicate), do: Enum.all?(items, predicate)
  defp quantify(items, :none, predicate), do: not Enum.any?(items, predicate)
  defp quantify(item, :is, nil), do: is_nil(item)
  defp quantify(item, :is, predicate), do: not is_nil(item) and predicate.(item)
  defp quantify(item, :is_not, predicate), do: not quantify(item, :is, predicate)

  defp scalar(:equals, expected), do: fn value -> value === expected end
  defp scalar(:not, expected), do: fn value -> value !== expected end

  defp scalar(op, expected) when op in [:in, :not_in] do
    values = MapSet.new(expected)
    fn value -> MapSet.member?(values, value) == (op == :in) end
  end

  defp scalar(:lt, expected), do: fn value -> not is_nil(value) and value < expected end
  defp scalar(:lte, expected), do: fn value -> not is_nil(value) and value <= expected end
  defp scalar(:gt, expected), do: fn value -> not is_nil(value) and value > expected end
  defp scalar(:gte, expected), do: fn value -> not is_nil(value) and value >= expected end

  defp scalar(:contains, expected),
    do: fn value -> not is_nil(value) and String.contains?(value, expected) end

  defp scalar(:starts_with, expected),
    do: fn value -> not is_nil(value) and String.starts_with?(value, expected) end

  defp scalar(:ends_with, expected),
    do: fn value -> not is_nil(value) and String.ends_with?(value, expected) end
end
