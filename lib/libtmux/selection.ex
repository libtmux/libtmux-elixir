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

  @typedoc "An ordered selection retaining items of one observation type and their originating snapshot."
  @opaque t(item) :: %__MODULE__{
            entity: Schema.entity_module(),
            items: [item],
            count: non_neg_integer(),
            snapshot: Snapshot.t()
          }
  @typedoc "A selection without a concrete observation type; use `t:t/1` to preserve item types."
  @type t :: t(Schema.observation())

  @doc """
  Materializes the observed items of an entity without I/O.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec new(Snapshot.t(), :session | LibTmux.Session) :: t(LibTmux.Session.t())
  @spec new(Snapshot.t(), :window | LibTmux.Window) :: t(LibTmux.Window.t())
  @spec new(Snapshot.t(), :pane | LibTmux.Pane) :: t(LibTmux.Pane.t())
  @spec new(Snapshot.t(), :window_link | LibTmux.WindowLink) :: t(LibTmux.WindowLink.t())
  @spec new(Snapshot.t(), :client | LibTmux.Client) :: t(LibTmux.Client.t())
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

  @doc """
  Returns cached materialized size in constant time.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{count: count}), do: count

  @doc """
  Filters validated data while retaining order and captured graph context.

  ## Examples

  One pane must satisfy both conditions inside `some`. Window `@0` has an
  active shell and an inactive editor; only `@1` has an active editor.
  See [filtering](filtering.html#predicate-grammar) for the complete semantics.

      iex> alias LibTmux.{Selection, Snapshot}
      iex> rows = %{window: [%{id: "@0"}, %{id: "@1"}], pane: [
      ...>   %{id: "%0", window_id: "@0", active: true, current_command: "bash"},
      ...>   %{id: "%1", window_id: "@0", active: false, current_command: "nvim"},
      ...>   %{id: "%2", window_id: "@1", active: true, current_command: "nvim"}]}
      iex> {:ok, snapshot} = Snapshot.new(rows,
      ...>   server_instance: "example", captured_from: 0, captured_until: 0,
      ...>   complete: [:pane], fields: %{pane: [:window_id, :active, :current_command]})
      iex> snapshot |> Snapshot.windows()
      ...> |> Selection.where(panes: [some: [active: true, current_command: "nvim"]])
      ...> |> Enum.map(& &1.id)
      ["@1"]
  """
  @spec where(t(item), Filter.input()) :: t(item) when item: Schema.observation()
  def where(%__MODULE__{} = selection, criteria) do
    filter(selection, predicate(selection, criteria))
  end

  @doc """
  Filters with a unary local function; normal predicate exceptions propagate.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec filter(t(item), (item -> as_boolean(term()))) :: t(item)
        when item: Schema.observation()
  def filter(%__MODULE__{} = selection, predicate) when is_function(predicate, 1) do
    items = Enum.filter(selection.items, predicate)
    %{selection | items: items, count: length(items)}
  end

  def filter(%__MODULE__{}, _predicate),
    do: raise(ArgumentError, "filter requires a unary function")

  @doc """
  Checks native identity separately from Enumerable element membership.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec member_id?(t(), LibTmux.Ref.id()) :: boolean()
  def member_id?(selection, id), do: Enum.any?(selection.items, &(&1.id == id))

  @doc """
  Returns exactly one match, or a structured cardinality error; stops at the second match.

  ## Examples

      iex> alias LibTmux.{Selection, Snapshot}
      iex> {:ok, snapshot} = Snapshot.new(%{pane: [%{id: "%0"}, %{id: "%1"}]},
      ...>   server_instance: "example", captured_from: 0, captured_until: 0,
      ...>   fields: %{pane: [:id]})
      iex> panes = Snapshot.panes(snapshot)
      iex> {:ok, pane} = Selection.one(panes, id: "%1")
      iex> pane.id
      "%1"
      iex> {:error, error} = Selection.one(panes, id: "%9")
      iex> error.kind
      :no_match
      iex> {:error, error} = Selection.one(panes)
      iex> error.kind
      :multiple_matches
  """
  @spec one(t(item), Filter.input()) :: {:ok, item} | {:error, Error.t()}
        when item: Schema.observation()
  def one(selection, criteria \\ []), do: cardinality(selection, criteria, false)

  @doc """
  Returns exactly one match or raises its cardinality error.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec one!(t(item), Filter.input()) :: item when item: Schema.observation()
  def one!(selection, criteria \\ []), do: unwrap(one(selection, criteria))

  @doc """
  Returns one match or nil; a second match remains an error.

  ## Examples

      iex> alias LibTmux.{Selection, Snapshot}
      iex> {:ok, snapshot} = Snapshot.new(%{pane: [%{id: "%0"}, %{id: "%1"}]},
      ...>   server_instance: "example", captured_from: 0, captured_until: 0,
      ...>   fields: %{pane: [:id]})
      iex> panes = Snapshot.panes(snapshot)
      iex> Selection.one_or_nil(panes, id: "%9")
      {:ok, nil}
      iex> {:ok, pane} = Selection.one_or_nil(panes, id: "%0")
      iex> pane.id
      "%0"
      iex> {:error, error} = Selection.one_or_nil(panes)
      iex> error.kind
      :multiple_matches
  """
  @spec one_or_nil(t(item), Filter.input()) :: {:ok, item | nil} | {:error, Error.t()}
        when item: Schema.observation()
  def one_or_nil(selection, criteria \\ []), do: cardinality(selection, criteria, true)

  @doc """
  Returns one match or nil, raising on multiple matches.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec one_or_nil!(t(item), Filter.input()) :: item | nil when item: Schema.observation()
  def one_or_nil!(selection, criteria \\ []), do: unwrap(one_or_nil(selection, criteria))

  @doc """
  Returns true on the first matching observed item.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec exists?(t(), Filter.input()) :: boolean()
  def exists?(selection, criteria \\ []),
    do: Enum.any?(selection.items, predicate(selection, criteria))

  @doc """
  Counts observed matching items; use size/1 for cached unfiltered size.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec count(t(), Filter.input()) :: non_neg_integer()
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
