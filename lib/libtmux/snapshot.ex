defmodule LibTmux.Snapshot do
  @moduledoc """
  An indexed immutable graph observed over a capture interval.

  Construction and traversal perform no I/O. `fields` declares loaded fields
  over the supplied entity IDs; `complete` declares complete server entity
  sets. Missing declarations remain unloaded, including on empty sets.
  Unavailable capabilities use a separate declaration. Relations require
  complete join domains. A snapshot reserves no tmux objects.
  """

  alias LibTmux.{Error, Ref, Schema}

  @collections %{
    session: :sessions,
    window: :windows,
    window_link: :window_links,
    pane: :panes,
    client: :clients
  }
  @foreign_keys %{
    pane: [window_id: :window],
    window_link: [session_id: :session, window_id: :window],
    client: [session_id: :session]
  }
  @enforce_keys [:id, :server_instance, :captured_from, :captured_until, :coverage]
  defstruct [
    :id,
    :server_instance,
    :captured_from,
    :captured_until,
    :coverage,
    schema_version: 1,
    sessions: %{},
    windows: %{},
    window_links: %{},
    panes: %{},
    clients: %{},
    order: %{},
    indexes: %{}
  ]

  @typedoc "Coverage of one captured entity domain; missing field entries are unloaded."
  @type entity_coverage :: %{
          ids: MapSet.t(Ref.id()),
          complete: boolean(),
          fields: %{optional(atom()) => :loaded | :unavailable}
        }
  @typedoc "Declared entity sets and field availability; completeness is separate from an empty captured set."
  @type coverage :: %{entities: %{Schema.entity() => entity_coverage()}}
  @typedoc "Maps each session ID to the IDs of its window links and clients, and each window ID to the IDs of its window links and panes. Traverse with `related/4`; the layout is not part of the contract."
  @opaque indexes :: %{
            session_links: %{optional(String.t()) => [Ref.id()]},
            window_links: %{optional(String.t()) => [Ref.id()]},
            window_panes: %{optional(Schema.observed(String.t())) => [String.t()]},
            session_clients: %{optional(Schema.observed(String.t())) => [String.t()]}
          }
  @typedoc "Observed rows grouped by canonical entity; construction validates and deduplicates their identities."
  @type rows :: %{optional(Schema.entity()) => [map() | Schema.observation()]}
  @typedoc "Construction metadata: one server instance, ordered millisecond timestamps and explicit coverage declarations."
  @type option ::
          {:server_instance, String.t()}
          | {:captured_from, integer()}
          | {:captured_until, integer()}
          | {:fields, %{optional(Schema.entity()) => [atom()]}}
          | {:complete, [Schema.entity()]}
          | {:unavailable, %{optional(Schema.entity()) => [atom()]}}

  @typedoc "An immutable observation interval with indexed entities and explicit coverage."
  @type t :: %__MODULE__{
          id: pos_integer(),
          server_instance: String.t(),
          captured_from: integer(),
          captured_until: integer(),
          coverage: coverage(),
          schema_version: 1,
          sessions: %{optional(String.t()) => LibTmux.Session.t()},
          windows: %{optional(String.t()) => LibTmux.Window.t()},
          window_links: %{optional(Ref.id()) => LibTmux.WindowLink.t()},
          panes: %{optional(String.t()) => LibTmux.Pane.t()},
          clients: %{optional(String.t()) => LibTmux.Client.t()},
          order: %{Schema.entity() => [Ref.id()]},
          indexes: indexes()
        }

  @doc "Validates observed rows, rejecting conflicts, invalid fields and dangling covered references."
  @spec new(rows(), [option()]) :: {:ok, t()} | {:error, Error.t()}
  def new(rows, options) do
    options =
      Keyword.validate!(options, [
        :server_instance,
        :captured_from,
        :captured_until,
        :fields,
        complete: [],
        unavailable: %{}
      ])

    instance = Keyword.fetch!(options, :server_instance)
    from = Keyword.fetch!(options, :captured_from)
    until = Keyword.fetch!(options, :captured_until)

    unless is_integer(from) and is_integer(until) and from <= until,
      do: raise(ArgumentError, "capture interval must be ordered integer timestamps")

    unless match?({:ok, _}, Ref.new(:session, "$0", instance)),
      do: raise(ArgumentError, "invalid server instance")

    try do
      options = validate_declarations!(options)

      for entity <- Map.keys(rows),
          entity not in Schema.entities(),
          do: fail(:invalid_entity, [entity])

      maps =
        Map.new(Schema.entities(), fn entity ->
          {entity,
           index_rows(
             entity,
             Map.get(rows, entity, []),
             instance,
             Map.get(options[:unavailable], entity, [])
           )}
        end)

      validate_links!(maps.window_link)
      coverage = coverage(maps, options)
      validate_references!(maps, coverage)

      snapshot =
        struct!(
          __MODULE__,
          Map.merge(Map.new(@collections, fn {entity, name} -> {name, maps[entity]} end), %{
            id: System.unique_integer([:positive, :monotonic]),
            server_instance: instance,
            captured_from: from,
            captured_until: until,
            coverage: coverage,
            order:
              Map.new(maps, fn {entity, items} ->
                {entity, items |> Map.keys() |> Enum.sort_by(&sort_key(entity, &1))}
              end),
            indexes: indexes(maps)
          })
        )

      {:ok, snapshot}
    catch
      %Error{} = error -> {:error, error}
    end
  end

  @doc "Returns plain observed items in stable identity order without loading data."
  @spec items(t(), Schema.entity_selector()) :: [Schema.observation()]
  def items(%__MODULE__{} = snapshot, entity) do
    entity = Schema.entity(entity)
    table = table(snapshot, entity)
    Enum.map(snapshot.order[entity], &Map.fetch!(table, &1))
  end

  @doc "Returns a materialized session selection without I/O."
  @spec sessions(t()) :: LibTmux.Selection.t(LibTmux.Session.t())
  def sessions(snapshot), do: LibTmux.Selection.new(snapshot, :session)
  @doc "Returns a materialized physical window selection without I/O."
  @spec windows(t()) :: LibTmux.Selection.t(LibTmux.Window.t())
  def windows(snapshot), do: LibTmux.Selection.new(snapshot, :window)
  @doc "Returns a materialized physical pane selection without I/O."
  @spec panes(t()) :: LibTmux.Selection.t(LibTmux.Pane.t())
  def panes(snapshot), do: LibTmux.Selection.new(snapshot, :pane)
  @doc "Returns a materialized membership selection without I/O."
  @spec window_links(t()) :: LibTmux.Selection.t(LibTmux.WindowLink.t())
  def window_links(snapshot), do: LibTmux.Selection.new(snapshot, :window_link)
  @doc "Returns a materialized attached-client selection without I/O."
  @spec clients(t()) :: LibTmux.Selection.t(LibTmux.Client.t())
  def clients(snapshot), do: LibTmux.Selection.new(snapshot, :client)

  @doc "Looks up one exact observed ID without I/O."
  @spec fetch(t(), Schema.entity_selector(), Ref.id()) ::
          {:ok, Schema.observation()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = snapshot, entity, id) do
    entity = Schema.entity(entity)

    case Map.fetch(table(snapshot, entity), id) do
      {:ok, item} ->
        {:ok, item}

      :error ->
        {:error,
         %Error{kind: :not_found, phase: :evaluation, certainty: :no_write, path: [entity, id]}}
    end
  end

  @doc "Requires a declared complete entity set, even when it has no rows."
  @spec require_complete!(t(), Schema.entity_selector()) :: :ok
  def require_complete!(snapshot, entity) do
    entity = Schema.entity(entity)

    unless snapshot.coverage.entities[entity].complete,
      do: raise_error(:entity_not_loaded, [entity])

    :ok
  end

  @doc "Requires a loaded field over the captured entity domain before evaluation."
  @spec require_field!(t(), Schema.entity_selector(), atom()) :: :ok
  def require_field!(snapshot, entity, field) do
    entity = Schema.entity(entity)
    unless Schema.field(entity, field), do: raise_error(:invalid_field, [entity, field])

    case Map.get(snapshot.coverage.entities[entity].fields, field, :unloaded) do
      :loaded -> :ok
      :unavailable -> raise_error(:field_unavailable, [entity, field])
      :unloaded -> raise_error(:field_not_loaded, [entity, field])
    end
  end

  @doc "Requires a complete relation domain, including known-empty domains."
  @spec require_relation!(t(), Schema.entity_selector(), atom(), :all | [Ref.id()]) :: :ok
  def require_relation!(snapshot, entity, relation, ids \\ :all) do
    entity = Schema.entity(entity)

    unless Map.has_key?(Schema.relations(entity), relation),
      do: raise_error(:invalid_relation, [entity, relation])

    coverage = relation_coverage(snapshot, entity, relation)
    ids = if ids == :all, do: snapshot.order[entity], else: ids

    unless coverage.loaded and Enum.all?(ids, &MapSet.member?(coverage.ids, &1)),
      do: raise_error(:relation_not_loaded, [entity, relation])

    :ok
  end

  @doc "Resolves a covered relation through captured indexes; never refreshes."
  @spec related(t(), Schema.entity_selector(), Ref.id(), atom()) ::
          Schema.observation() | nil | [Schema.observation()]
  def related(snapshot, entity, id, relation) do
    entity = Schema.entity(entity)
    require_relation!(snapshot, entity, relation, [id])
    {:ok, item} = fetch(snapshot, entity, id)
    project(snapshot, entity, item, relation)
  end

  defp index_rows(entity, rows, instance, unavailable) when is_list(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      row = if is_struct(row), do: Map.from_struct(row), else: row
      fields = Schema.fields(entity)

      for key <- Map.keys(row),
          key != :server_instance and not Map.has_key?(fields, key),
          do: fail(:invalid_field, [entity, key])

      if Map.has_key?(row, :server_instance) and row.server_instance != instance,
        do: fail(:stale_target, [entity])

      row = if entity == :window_link, do: bind_link(row), else: row
      id = row[:id]

      unless match?({:ok, _}, Ref.new(entity, id, instance)),
        do: fail(:invalid_target, [entity, id])

      Enum.each(row, fn
        {:server_instance, _} ->
          :ok

        {_key, value} when value in [:unloaded, :unavailable] ->
          :ok

        {key, value} ->
          unless Schema.valid_value?(fields[key], value),
            do: fail(:invalid_field, [entity, id, key])
      end)

      row =
        Enum.reduce(unavailable, row, fn field, current ->
          unless Map.get(current, field, :unloaded) in [:unloaded, :unavailable],
            do: fail(:inconsistent_coverage, [entity, field])

          Map.put(current, field, :unavailable)
        end)

      row =
        if entity == :session,
          do: Map.put(row, :attached, attached(Map.get(row, :attached_count, :unloaded))),
          else: row

      item = struct!(Schema.module(entity), Map.put(row, :server_instance, instance))

      case Map.fetch(acc, id) do
        {:ok, ^item} -> acc
        {:ok, _other} -> fail(:conflicting_rows, [entity, id])
        :error -> Map.put(acc, id, item)
      end
    end)
  end

  defp bind_link(row) do
    id = {row[:session_id], row[:index], row[:window_id]}
    if Map.has_key?(row, :id) and row.id != id, do: fail(:invalid_target, [:window_link, row.id])
    Map.put(row, :id, id)
  end

  defp attached(count) when is_integer(count), do: count > 0
  defp attached(state), do: state

  defp validate_links!(links) do
    Enum.reduce(links, %{}, fn {_, link}, seen ->
      key = {link.session_id, link.index}

      if Map.has_key?(seen, key) and seen[key] != link.window_id,
        do: fail(:conflicting_link, [:window_link, link.id])

      Map.put(seen, key, link.window_id)
    end)
  end

  defp coverage(maps, options) do
    declared = Keyword.get(options, :fields, %{})
    unavailable = options[:unavailable]
    complete = options[:complete]

    for entity <- Map.keys(declared) ++ Map.keys(unavailable) ++ complete,
        entity not in Schema.entities(),
        do: fail(:invalid_entity, [entity])

    entities =
      Map.new(maps, fn {entity, items} ->
        fields = Map.get(declared, entity, [])
        missing = Map.get(unavailable, entity, [])

        for field <- fields ++ missing,
            is_nil(Schema.field(entity, field)),
            do: fail(:invalid_field, [entity, field])

        if Enum.any?(fields, &(&1 in missing)), do: fail(:inconsistent_coverage, [entity])

        fields =
          if entity == :session and :attached_count in fields,
            do: Enum.uniq([:attached | fields]),
            else: fields

        Enum.each(fields, fn field ->
          if Enum.any?(items, fn {_, item} ->
               Map.fetch!(item, field) in [:unloaded, :unavailable]
             end),
             do: fail(:inconsistent_coverage, [entity, field])
        end)

        Enum.each(missing, fn field ->
          if Enum.any?(items, fn {_, item} ->
               Map.fetch!(item, field) not in [:unloaded, :unavailable]
             end),
             do: fail(:inconsistent_coverage, [entity, field])
        end)

        states = Map.merge(Map.new(fields, &{&1, :loaded}), Map.new(missing, &{&1, :unavailable}))

        {entity,
         %{ids: MapSet.new(Map.keys(items)), complete: entity in complete, fields: states}}
      end)

    %{entities: entities}
  end

  defp validate_declarations!(options) do
    fields = Keyword.get(options, :fields, %{})
    unavailable = options[:unavailable]

    for entity <- Map.keys(fields) ++ Map.keys(unavailable) ++ options[:complete],
        entity not in Schema.entities(),
        do: fail(:invalid_entity, [entity])

    for declarations <- [fields, unavailable],
        {entity, names} <- declarations,
        name <- names,
        is_nil(Schema.field(entity, name)),
        do: fail(:invalid_field, [entity, name])

    fields = derived_coverage(fields)
    unavailable = derived_coverage(unavailable)

    for entity <- Schema.entities(),
        field <- Map.get(fields, entity, []),
        field in Map.get(unavailable, entity, []),
        do: fail(:inconsistent_coverage, [entity, field])

    options |> Keyword.put(:fields, fields) |> Keyword.put(:unavailable, unavailable)
  end

  defp derived_coverage(declarations) do
    names = Map.get(declarations, :session, [])

    if :attached in names and :attached_count not in names,
      do: fail(:inconsistent_coverage, [:session, :attached])

    if :attached_count in names,
      do: Map.put(declarations, :session, Enum.uniq([:attached | names])),
      else: declarations
  end

  defp validate_references!(maps, coverage) do
    for {entity, keys} <- @foreign_keys, {_, item} <- maps[entity], {field, target} <- keys do
      value = Map.fetch!(item, field)

      if value not in [:unloaded, :unavailable, nil] and coverage.entities[target].complete and
           not Map.has_key?(maps[target], value),
         do: fail(:inconsistent_snapshot, [entity, item.id, field])
    end
  end

  defp indexes(maps) do
    %{
      session_links: grouped(maps.window_link, :session_id, & &1.index),
      window_links: grouped(maps.window_link, :window_id, &sort_key(:window_link, &1.id)),
      window_panes: grouped(maps.pane, :window_id, &sort_key(:pane, &1.id)),
      session_clients: grouped(maps.client, :session_id, & &1.id)
    }
  end

  defp grouped(items, field, order) do
    items
    |> Map.values()
    |> Enum.group_by(&Map.fetch!(&1, field))
    |> Map.new(fn {id, rows} -> {id, rows |> Enum.sort_by(order) |> Enum.map(& &1.id)} end)
  end

  defp relation_coverage(snapshot, entity, relation) do
    {complete, required} = requirements(entity, relation)

    loaded =
      Enum.all?(complete, &snapshot.coverage.entities[&1].complete) and
        Enum.all?(required, fn {e, f} -> snapshot.coverage.entities[e].fields[f] == :loaded end)

    ids =
      if loaded,
        do:
          Enum.filter(snapshot.order[entity], fn id ->
            relation_targets_present?(snapshot, entity, id, relation)
          end),
        else: []

    %{loaded: loaded, ids: MapSet.new(ids)}
  end

  defp requirements(:pane, :window), do: {[], [pane: :window_id]}
  defp requirements(:client, :session), do: {[], [client: :session_id]}
  defp requirements(:window_link, :session), do: {[], [window_link: :session_id]}
  defp requirements(:window_link, :window), do: {[], [window_link: :window_id]}
  defp requirements(:window, :panes), do: {[:pane], [pane: :window_id]}
  defp requirements(:session, :clients), do: {[:client], [client: :session_id]}

  defp requirements(:session, :active_window),
    do:
      {[:window_link], [window_link: :session_id, window_link: :window_id, window_link: :active]}

  defp requirements(:session, :panes),
    do:
      {[:window_link, :pane],
       [window_link: :session_id, window_link: :window_id, pane: :window_id]}

  defp requirements(_entity, _relation),
    do: {[:window_link], [window_link: :session_id, window_link: :window_id]}

  defp relation_targets_present?(snapshot, :session, id, :active_window) do
    case active_link(snapshot, snapshot.sessions[id]) do
      nil -> true
      link -> Map.has_key?(snapshot.windows, link.window_id)
    end
  end

  defp relation_targets_present?(snapshot, entity, id, relation) do
    {cardinality, _target} = Schema.relations(entity)[relation]
    result = project(snapshot, entity, table(snapshot, entity)[id], relation)
    if cardinality == :one, do: not is_nil(result), else: Enum.all?(result, &(not is_nil(&1)))
  end

  defp project(s, :pane, item, :window), do: s.windows[item.window_id]
  defp project(s, :client, item, :session), do: s.sessions[item.session_id]
  defp project(s, :window_link, item, :session), do: s.sessions[item.session_id]
  defp project(s, :window_link, item, :window), do: s.windows[item.window_id]

  defp project(s, :session, item, :active_window) do
    case active_link(s, item) do
      nil -> nil
      link -> s.windows[link.window_id]
    end
  end

  defp project(s, :window, item, :panes),
    do: Enum.map(Map.get(s.indexes.window_panes, item.id, []), &s.panes[&1])

  defp project(s, :session, item, :clients),
    do: Enum.map(Map.get(s.indexes.session_clients, item.id, []), &s.clients[&1])

  defp project(s, :session, item, :window_links),
    do: Enum.map(Map.get(s.indexes.session_links, item.id, []), &s.window_links[&1])

  defp project(s, :window, item, :window_links),
    do: Enum.map(Map.get(s.indexes.window_links, item.id, []), &s.window_links[&1])

  defp project(s, :session, item, :windows),
    do:
      project(s, :session, item, :window_links)
      |> Enum.map(&s.windows[&1.window_id])
      |> Enum.uniq_by(&if(&1, do: &1.id))

  defp project(s, :window, item, :sessions),
    do:
      project(s, :window, item, :window_links)
      |> Enum.map(&s.sessions[&1.session_id])
      |> Enum.uniq_by(&if(&1, do: &1.id))
      |> Enum.sort_by(&if(&1, do: sort_key(:session, &1.id)))

  defp project(s, :session, item, :panes) do
    windows =
      project(s, :session, item, :window_links) |> Enum.map(& &1.window_id) |> MapSet.new()

    items(s, :pane) |> Enum.filter(&MapSet.member?(windows, &1.window_id))
  end

  defp table(snapshot, entity), do: Map.fetch!(snapshot, @collections[entity])

  defp active_link(snapshot, session) do
    case Enum.filter(project(snapshot, :session, session, :window_links), & &1.active) do
      [] -> nil
      [link] -> link
      _ -> raise_error(:ambiguous_relation, [:session, session.id, :active_window])
    end
  end

  defp sort_key(:window_link, {session, index, window}),
    do: {sort_key(:session, session), index, sort_key(:window, window)}

  defp sort_key(:client, id), do: id
  defp sort_key(_entity, <<_prefix, digits::binary>>), do: String.to_integer(digits)

  defp fail(kind, path),
    do: throw(%Error{kind: kind, phase: :capture, certainty: :no_write, path: path})

  defp raise_error(kind, path),
    do: raise(Error, kind: kind, phase: :evaluation, certainty: :no_write, path: path)
end
