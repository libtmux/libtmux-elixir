defmodule LibTmux.Filter.Evaluator do
  @moduledoc false
  alias LibTmux.{Schema, Snapshot}

  def prepare(filter, %Snapshot{} = snapshot), do: compile(filter.tree, filter.entity, snapshot)

  defp compile({:and, children}, entity, snapshot) do
    predicates = Enum.map(children, &compile(&1, entity, snapshot))
    fn item -> Enum.all?(predicates, & &1.(item)) end
  end

  defp compile({:or, children}, entity, snapshot) do
    predicates = Enum.map(children, &compile(&1, entity, snapshot))
    fn item -> Enum.any?(predicates, & &1.(item)) end
  end

  defp compile({:not, child}, entity, snapshot) do
    predicate = compile(child, entity, snapshot)
    fn item -> not predicate.(item) end
  end

  defp compile({:field, field, op, value}, entity, snapshot) do
    Snapshot.require_field!(snapshot, entity, field)
    predicate = scalar(op, value)
    fn item -> predicate.(Map.fetch!(item, field)) end
  end

  defp compile({:count, relation, operators}, entity, snapshot) do
    Snapshot.require_relation!(snapshot, entity, relation)
    predicates = Enum.map(operators, fn {op, value} -> scalar(op, value) end)

    fn item ->
      count = snapshot |> Snapshot.related(entity, item.id, relation) |> length()
      Enum.all?(predicates, & &1.(count))
    end
  end

  defp compile({:relation, relation, op, child}, entity, snapshot) do
    Snapshot.require_relation!(snapshot, entity, relation)
    {_cardinality, target} = Schema.relations(entity)[relation]
    predicate = if is_nil(child), do: nil, else: compile(child, target, snapshot)
    fn item -> quantify(Snapshot.related(snapshot, entity, item.id, relation), op, predicate) end
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
