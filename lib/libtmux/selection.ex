defmodule LibTmux.Selection do
  @moduledoc """
  An ordered, materialized Enumerable over one captured entity type.

  Enumeration never refreshes or performs I/O. `where/2` accepts predicate
  data; `filter/2` accepts unary Elixir functions with Enum truthiness.
  Holding a selection retains its snapshot graph. `Enum.to_list/1` projects
  ordinary values when graph context is no longer needed.
  """

  alias LibTmux.{Error, Filter, Schema, Snapshot}
  @enforce_keys [:entity, :items, :count, :snapshot]
  defstruct [:entity, :items, :count, :snapshot]

  @opaque t(item) :: %__MODULE__{
            entity: module(),
            items: [item],
            count: non_neg_integer(),
            snapshot: Snapshot.t()
          }

  @doc "Materializes the observed items of an entity without I/O."
  def new(%Snapshot{} = snapshot, entity) do
    entity = Schema.entity(entity)
    items = Snapshot.items(snapshot, entity)

    %__MODULE__{
      entity: Schema.module(entity),
      items: items,
      count: length(items),
      snapshot: snapshot
    }
  end

  @doc "Returns cached materialized size in constant time."
  def size(%__MODULE__{count: count}), do: count

  @doc "Filters validated data while retaining order and captured graph context."
  def where(%__MODULE__{} = selection, criteria) do
    filter(selection, predicate(selection, criteria))
  end

  @doc "Filters with a unary local function; normal predicate exceptions propagate."
  def filter(%__MODULE__{} = selection, predicate) when is_function(predicate, 1) do
    items = Enum.filter(selection.items, predicate)
    %{selection | items: items, count: length(items)}
  end

  def filter(%__MODULE__{}, _predicate),
    do: raise(ArgumentError, "filter requires a unary function")

  @doc "Checks native identity separately from Enumerable element membership."
  def member_id?(selection, id), do: Enum.any?(selection.items, &(&1.id == id))

  @doc "Returns exactly one match, or a structured cardinality error; stops at the second match."
  def one(selection, criteria \\ []), do: cardinality(selection, criteria, false)

  @doc "Returns exactly one match or raises its cardinality error."
  def one!(selection, criteria \\ []), do: unwrap(one(selection, criteria))

  @doc "Returns one match or nil; a second match remains an error."
  def one_or_nil(selection, criteria \\ []), do: cardinality(selection, criteria, true)

  @doc "Returns one match or nil, raising on multiple matches."
  def one_or_nil!(selection, criteria \\ []), do: unwrap(one_or_nil(selection, criteria))

  @doc "Returns true on the first matching observed item."
  def exists?(selection, criteria \\ []),
    do: Enum.any?(selection.items, predicate(selection, criteria))

  @doc "Counts observed matching items; use size/1 for cached unfiltered size."
  def count(selection, criteria \\ []),
    do: Enum.count(selection.items, predicate(selection, criteria))

  defp predicate(selection, criteria) do
    selection.entity |> Filter.new!(criteria) |> Filter.to_predicate(snapshot: selection.snapshot)
  end

  defp cardinality(selection, criteria, allow_nil) do
    predicate = predicate(selection, criteria)

    matches =
      Enum.reduce_while(selection.items, [], fn item, matches ->
        if predicate.(item) do
          case matches do
            [] -> {:cont, [item]}
            [_] -> {:halt, :multiple}
          end
        else
          {:cont, matches}
        end
      end)

    case matches do
      [item] ->
        {:ok, item}

      [] when allow_nil ->
        {:ok, nil}

      [] ->
        {:error, %Error{kind: :no_match, phase: :evaluation, certainty: :no_write}}

      :multiple ->
        {:error,
         %Error{
           kind: :multiple_matches,
           phase: :evaluation,
           certainty: :no_write,
           details: %{at_least: 2}
         }}
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, error}), do: raise(error)
end

defimpl Enumerable, for: LibTmux.Selection do
  def reduce(%{items: items}, accumulator, reducer),
    do: Enumerable.List.reduce(items, accumulator, reducer)

  def count(%{count: count}), do: {:ok, count}
  def member?(_selection, _value), do: {:error, __MODULE__}
  def slice(_selection), do: {:error, __MODULE__}
end

defimpl Inspect, for: LibTmux.Selection do
  import Inspect.Algebra

  def inspect(selection, _options) do
    concat([
      "#LibTmux.Selection<",
      selection.entity |> Module.split() |> List.last(),
      " count=",
      Integer.to_string(selection.count),
      " snapshot=",
      Integer.to_string(selection.snapshot.id),
      ">"
    ])
  end
end
