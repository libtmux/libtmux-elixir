defmodule LibTmux.Filter do
  @moduledoc """
  A validated portable predicate over one observed entity type.

  Keywords are trusted shorthand for maps. Fields in one object conjoin;
  duplicate keyword keys are rejected recursively. `not` at a field negates
  equality, while Boolean `not` takes one criteria object. Lists require an
  explicit operator. Native callbacks belong to `LibTmux.Selection.filter/2`.
  This value contains data; executable preparation remains separate.
  """

  alias LibTmux.{Error, Schema}
  @enforce_keys [:entity, :tree]
  defstruct [:entity, :tree]

  @typedoc "Local map criteria or keyword shorthand; field and operand domains are validated at construction."
  @type criteria :: %{optional(atom()) => term()} | keyword(term())
  @typedoc "Trusted criteria data or a previously validated filter for the same entity."
  @type input :: criteria() | t()
  @typedoc "A positive resource ceiling; byte, depth, node, list and string budgets validate independently."
  @type limit_option ::
          {:max_bytes, pos_integer()}
          | {:max_depth, pos_integer()}
          | {:max_nodes, pos_integer()}
          | {:max_list, pos_integer()}
          | {:max_string_bytes, pos_integer()}
  @typedoc "Resolved constructor budgets; wire limits also cover the versioned envelope."
  @type limits :: %{
          max_bytes: pos_integer(),
          max_depth: pos_integer(),
          max_nodes: pos_integer(),
          max_list: pos_integer(),
          max_string_bytes: pos_integer()
        }
  @typep scalar :: binary() | non_neg_integer() | boolean() | nil | LibTmux.Ref.id()
  @typep predicate_node ::
           {:and | :or, [predicate_node()]}
           | {:not, predicate_node()}
           | {:field, atom(), Schema.operator(), scalar() | [scalar()]}
           | {:count, atom(), [{Schema.operator(), non_neg_integer() | [non_neg_integer()]}]}
           | {:relation, atom(), :some | :every | :none | :is | :is_not, predicate_node() | nil}

  @typedoc "Validated portable predicate data; executable predicates are prepared separately."
  @opaque t :: %__MODULE__{entity: Schema.entity(), tree: predicate_node()}

  @doc """
  Normalizes criteria and validates field/operator/value domains before evaluation.

  An existing filter retains its constructor's validation when no new limits
  are supplied. Explicit limits check the normalized tree directly, without
  expanding it into synthetic input syntax.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec new(Schema.entity_selector(), input(), [limit_option()]) ::
          {:ok, t()} | {:error, Error.t()}
  def new(entity, criteria, options \\ [])

  def new(entity, %__MODULE__{} = filter, []) do
    if Schema.entity(entity) == filter.entity,
      do: {:ok, filter},
      else:
        {:error,
         %Error{
           kind: :invalid_filter,
           certainty: :no_write,
           path: [:entity],
           details: %{code: :entity_mismatch}
         }}
  end

  def new(entity, criteria, options) do
    entity = Schema.entity(entity)

    try do
      state = %{limits: limits(options), nodes: 0, bytes: 0}

      tree =
        case criteria do
          %__MODULE__{entity: ^entity, tree: tree} ->
            tree

          %__MODULE__{} ->
            invalid([:entity], :entity_mismatch)

          value ->
            {tree, _state} = normalize(entity, value, state, [], 0)
            tree
        end

      check_tree(tree, entity, state, [], 0)
      {:ok, %__MODULE__{entity: entity, tree: tree}}
    catch
      %Error{} = error -> {:error, error}
    end
  end

  @doc """
  Constructs a filter or raises its structured validation error.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec new!(Schema.entity_selector(), input(), [limit_option()]) :: t()
  def new!(entity, criteria, options \\ []) do
    case new(entity, criteria, options) do
      {:ok, filter} -> filter
      {:error, error} -> raise error
    end
  end

  @doc """
  Prepares a local unary predicate after validating captured coverage, including empty domains.

  Relationship and count predicates require each input to equal the
  observation stored under its ID in `snapshot`. A missing or different
  observation raises `LibTmux.Error` with kind `:observation_mismatch`.
  Related values always come from the prepared snapshot; equal inputs from
  another capture are accepted.

  Scalar-only predicates read the supplied observation. Their snapshot is
  used only to validate captured coverage.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec to_predicate(t(), [{:snapshot, LibTmux.Snapshot.t()}]) ::
          (Schema.observation() -> boolean())
  def to_predicate(%__MODULE__{} = filter, options) do
    filter = new!(filter.entity, filter)
    LibTmux.Filter.Evaluator.prepare(filter, Keyword.fetch!(options, :snapshot))
  end

  @doc """
  Decodes a whitelisted versioned map; raw JSON must use from_json to retain duplicate keys.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec from_wire(Schema.entity_selector(), term(), [limit_option()]) ::
          {:ok, t()} | {:error, Error.t()}
  def from_wire(entity, payload, options \\ []),
    do: LibTmux.Filter.Wire.decode(entity, payload, options)

  @doc """
  Decodes bounded JSON, rejecting duplicate object keys and trailing data.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec from_json(Schema.entity_selector(), binary(), [limit_option()]) ::
          {:ok, t()} | {:error, Error.t()}
  def from_json(entity, json, options \\ []),
    do: LibTmux.Filter.Wire.decode_json(entity, json, options)

  @doc """
  Returns the explicit versioned string-keyed wire representation.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec to_wire(t()) :: LibTmux.Wire.object()
  def to_wire(%__MODULE__{} = filter), do: LibTmux.Filter.Wire.encode(new!(filter.entity, filter))

  @doc false
  @spec limits([limit_option()]) :: limits()
  def limits(options) do
    values =
      Keyword.validate!(options,
        max_bytes: 65_536,
        max_depth: 16,
        max_nodes: 1024,
        max_list: 256,
        max_string_bytes: 8192
      )

    unless Enum.all?(values, fn {_, value} -> is_integer(value) and value > 0 end),
      do: raise(ArgumentError, "filter budgets must be positive integers")

    Map.new(values)
  end

  defp normalize(entity, criteria, state, path, depth) do
    state = enter(state, path, depth)

    {nodes, state} =
      object(criteria, path)
      |> Enum.sort()
      |> Enum.map_reduce(state, fn {key, value}, state ->
        location = path ++ [key]

        cond do
          key in [:and, :or] ->
            unless (is_list(value) and not Keyword.keyword?(value)) or value == [],
              do: invalid(location, :expected_criteria_list)

            check_list(value, state, location)

            {children, state} =
              value
              |> Enum.with_index()
              |> Enum.map_reduce(state, fn {child, index}, state ->
                normalize(entity, child, state, location ++ [index], depth + 1)
              end)

            {{key, Enum.sort(Enum.uniq(children))}, state}

          key == :not ->
            {child, state} = normalize(entity, value, state, location, depth + 1)
            {{:not, child}, state}

          metadata = Schema.field(entity, key) ->
            {operators, state} = operators(metadata, value, state, location)

            {conjoin(Enum.map(operators, fn {op, operand} -> {:field, key, op, operand} end)),
             state}

          relation = Schema.relations(entity)[key] ->
            relation(entity, key, relation, value, state, location, depth + 1)

          true ->
            invalid(location, :unknown_field)
        end
      end)

    {conjoin(nodes), state}
  end

  defp relation(_entity, name, {cardinality, target}, criteria, state, path, depth) do
    pairs = object(criteria, path)
    if pairs == [], do: invalid(path, :empty_operators)

    {nodes, state} =
      Enum.sort(pairs)
      |> Enum.map_reduce(state, fn {op, value}, state ->
        location = path ++ [op]

        cond do
          cardinality == :many and op == :count ->
            {operators, state} =
              operators(%{type: :integer, nullable: false}, value, state, location)

            {{:count, name, operators}, state}

          cardinality == :many and op in [:some, :every, :none] ->
            {child, state} = normalize(target, value, state, location, depth)
            {{:relation, name, op, child}, state}

          cardinality == :one and op in [:is, :is_not] ->
            if is_nil(value) do
              {{:relation, name, op, nil}, enter(state, location, depth)}
            else
              {child, state} = normalize(target, value, state, location, depth)
              {{:relation, name, op, child}, state}
            end

          true ->
            invalid(location, :unsupported_operator)
        end
      end)

    {conjoin(nodes), state}
  end

  defp operators(metadata, criteria, state, path) do
    pairs =
      if is_map(criteria) or is_list(criteria),
        do: object(criteria, path),
        else: [equals: criteria]

    if pairs == [], do: invalid(path, :empty_operators)

    Enum.sort(pairs)
    |> Enum.map_reduce(state, fn {op, operand}, state ->
      location = path ++ [op]
      unless op in Schema.operators(metadata), do: invalid(location, :unsupported_operator)

      values =
        if op in [:in, :not_in] do
          check_list(operand, state, location)
          operand
        else
          [operand]
        end

      state =
        values
        |> Enum.with_index()
        |> Enum.reduce(state, fn {value, index}, state ->
          value_path = if op in [:in, :not_in], do: location ++ [index], else: location

          if op in [:lt, :lte, :gt, :gte, :contains, :starts_with, :ends_with] and is_nil(value),
            do: invalid(value_path, :invalid_value)

          unless Schema.valid_value?(metadata, value), do: invalid(value_path, :invalid_value)
          bytes = if is_binary(value), do: byte_size(value), else: 0

          if bytes > state.limits.max_string_bytes or state.bytes + bytes > state.limits.max_bytes,
            do: limited(value_path, :bytes)

          %{state | bytes: state.bytes + bytes}
        end)

      {{op, operand}, enter(state, location, 0)}
    end)
  end

  defp object(criteria, _path) when is_map(criteria) and not is_struct(criteria),
    do: Map.to_list(criteria)

  defp object(criteria, path) when is_list(criteria) do
    unless Keyword.keyword?(criteria), do: invalid(path, :expected_object)
    keys = Keyword.keys(criteria)
    if length(keys) != MapSet.size(MapSet.new(keys)), do: invalid(path, :duplicate_key)
    criteria
  end

  defp object(_criteria, path), do: invalid(path, :expected_object)

  defp enter(state, path, depth) do
    if depth > state.limits.max_depth, do: limited(path, :depth)
    if state.nodes >= state.limits.max_nodes, do: limited(path, :nodes)
    %{state | nodes: state.nodes + 1}
  end

  defp check_list(value, state, path) do
    unless is_list(value), do: invalid(path, :expected_list)
    if length(value) > state.limits.max_list, do: limited(path, :list)
  end

  defp conjoin(nodes) do
    nodes = nodes |> Enum.flat_map(&conjuncts/1) |> Enum.uniq() |> Enum.sort()

    case nodes do
      [node] -> node
      _ -> {:and, nodes}
    end
  end

  defp conjuncts({:and, children}), do: Enum.flat_map(children, &conjuncts/1)
  defp conjuncts(node), do: [node]

  defp check_tree({kind, children}, entity, state, path, depth) when kind in [:and, :or] do
    state = enter(state, path, depth)
    check_list(children, state, path)
    child_depth = if kind == :and, do: depth, else: depth + 1

    children
    |> Enum.with_index()
    |> Enum.reduce(state, fn {child, index}, state ->
      check_tree(child, entity, state, path ++ [kind, index], child_depth)
    end)
  end

  defp check_tree({:not, child}, entity, state, path, depth) do
    check_tree(child, entity, enter(state, path, depth), path ++ [:not], depth + 1)
  end

  defp check_tree({:field, field, op, value}, entity, state, path, depth) do
    if depth > state.limits.max_depth, do: limited(path, :depth)
    metadata = Schema.field(entity, field) || invalid(path ++ [field], :unknown_field)
    {_, state} = operators(metadata, %{op => value}, state, path ++ [field])
    state
  end

  defp check_tree({:count, relation, ops}, entity, state, path, depth) do
    if depth > state.limits.max_depth, do: limited(path, :depth)

    unless match?({:many, _}, Schema.relations(entity)[relation]),
      do: invalid(path ++ [relation], :unsupported_operator)

    {_, state} =
      operators(%{type: :integer, nullable: false}, ops, state, path ++ [relation, :count])

    state
  end

  defp check_tree({:relation, relation, op, child}, entity, state, path, depth) do
    state = enter(state, path, depth)

    case Schema.relations(entity)[relation] do
      {:many, target} when op in [:some, :every, :none] ->
        check_tree(child, target, state, path ++ [relation, op], depth + 1)

      {:one, _target} when op in [:is, :is_not] and is_nil(child) ->
        state

      {:one, target} when op in [:is, :is_not] ->
        check_tree(child, target, state, path ++ [relation, op], depth + 1)

      _ ->
        invalid(path ++ [relation], :unsupported_operator)
    end
  end

  defp check_tree(_tree, _entity, _state, path, _depth), do: invalid(path, :invalid_tree)

  defp invalid(path, code),
    do:
      throw(%Error{
        kind: :invalid_filter,
        certainty: :no_write,
        path: path,
        details: %{code: code}
      })

  defp limited(path, code),
    do:
      throw(%Error{
        kind: :resource_limit,
        certainty: :no_write,
        path: path,
        details: %{code: code}
      })
end
