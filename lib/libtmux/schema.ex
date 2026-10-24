defmodule LibTmux.Schema do
  @moduledoc """
  Defines observed fields, wire names and graph relations.

  The table is a semantic overlay on tmux 3.3 format variables. It drives
  observation validation, portable filtering and reference generation. Empty text
  remains text; only explicitly nullable fields admit `nil`.
  """

  @typedoc "An entity's canonical local name. Physical windows and membership links are distinct."
  @type entity :: :session | :window | :window_link | :pane | :client

  @typedoc "The observation struct modules accepted alongside canonical entity names."
  @type entity_module ::
          LibTmux.Session | LibTmux.Window | LibTmux.WindowLink | LibTmux.Pane | LibTmux.Client

  @typedoc "A canonical entity atom or its corresponding observation module."
  @type entity_selector :: entity() | entity_module()

  @typedoc "A known value, unloaded coverage, or an unavailable capability; nil belongs to the value type."
  @type observed(value) :: value | :unloaded | :unavailable

  @typedoc "One physical or contextual observation from a captured graph."
  @type observation ::
          LibTmux.Session.t()
          | LibTmux.Window.t()
          | LibTmux.WindowLink.t()
          | LibTmux.Pane.t()
          | LibTmux.Client.t()

  @typedoc "A field's validation category; integer fields use the schema's nonnegative 32-bit range."
  @type value_type :: :string | :integer | :nullable_integer | :boolean | {:id, entity()}
  @typedoc "Field metadata shared by validation and documentation; nil format identifies a derived field."
  @type field :: %{
          name: atom(),
          wire: String.t(),
          format: String.t() | nil,
          type: value_type(),
          since: String.t(),
          nullable: boolean()
        }
  @typedoc "The cardinality and target entity of one indexed graph relation."
  @type relation :: {:one | :many, entity()}
  @typedoc "A scalar filter operator; each field category permits only its applicable subset."
  @type operator ::
          :equals
          | :not
          | :in
          | :not_in
          | :lt
          | :lte
          | :gt
          | :gte
          | :contains
          | :starts_with
          | :ends_with

  @entities [:session, :window, :window_link, :pane, :client]
  @modules %{
    session: LibTmux.Session,
    window: LibTmux.Window,
    window_link: LibTmux.WindowLink,
    pane: LibTmux.Pane,
    client: LibTmux.Client
  }
  @fields %{
    session: [
      {:id, "id", "session_id", {:id, :session}},
      {:name, "name", "session_name", :string},
      {:attached_count, "attachedCount", "session_attached", :integer},
      {:attached, "attached", nil, :boolean}
    ],
    window: [
      {:id, "id", "window_id", {:id, :window}},
      {:name, "name", "window_name", :string},
      {:width, "width", "window_width", :integer},
      {:height, "height", "window_height", :integer},
      {:layout, "layout", "window_layout", :string},
      {:zoomed, "zoomed", "window_zoomed_flag", :boolean}
    ],
    window_link: [
      {:id, "id", nil, {:id, :window_link}},
      {:session_id, "sessionId", "session_id", {:id, :session}},
      {:window_id, "windowId", "window_id", {:id, :window}},
      {:index, "index", "window_index", :integer},
      {:active, "active", "window_active", :boolean}
    ],
    pane: [
      {:id, "id", "pane_id", {:id, :pane}},
      {:window_id, "windowId", "window_id", {:id, :window}},
      {:index, "index", "pane_index", :integer},
      {:active, "active", "pane_active", :boolean},
      {:dead, "dead", "pane_dead", :boolean},
      {:width, "width", "pane_width", :integer},
      {:height, "height", "pane_height", :integer},
      {:pid, "pid", "pane_pid", :nullable_integer},
      {:current_command, "currentCommand", "pane_current_command", :string},
      {:current_path, "currentPath", "pane_current_path", :string},
      {:title, "title", "pane_title", :string},
      {:exit_status, "exitStatus", "pane_dead_status", :nullable_integer}
    ],
    client: [
      {:id, "id", "client_name", {:id, :client}},
      {:session_id, "sessionId", "session_id", {:id, :session}},
      {:pid, "pid", "client_pid", :integer},
      {:width, "width", "client_width", :integer},
      {:height, "height", "client_height", :nullable_integer},
      {:control_mode, "controlMode", "client_control_mode", :boolean}
    ]
  }
  @relations %{
    session: %{
      active_window: {:one, :window},
      windows: {:many, :window},
      window_links: {:many, :window_link},
      panes: {:many, :pane},
      clients: {:many, :client}
    },
    window: %{
      sessions: {:many, :session},
      window_links: {:many, :window_link},
      panes: {:many, :pane}
    },
    pane: %{window: {:one, :window}},
    window_link: %{session: {:one, :session}, window: {:one, :window}},
    client: %{session: {:one, :session}}
  }
  @relation_names %{
    active_window: "activeWindow",
    windows: "windows",
    window_links: "windowLinks",
    panes: "panes",
    clients: "clients",
    sessions: "sessions",
    session: "session",
    window: "window"
  }

  @doc """
  Returns supported entity names in a stable order.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec entities() :: [entity()]
  def entities, do: @entities

  @doc """
  Returns the ordinary observation struct module for an entity.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec module(entity()) :: entity_module()
  def module(entity), do: Map.fetch!(@modules, entity)

  @doc """
  Resolves an entity atom or its observation module.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec entity(entity_selector()) :: entity()
  def entity(entity) when entity in @entities, do: entity

  def entity(module),
    do:
      Enum.find_value(@modules, fn {entity, value} -> if value == module, do: entity end) ||
        raise(ArgumentError, "unknown entity")

  @doc """
  Returns the whitelisted field metadata for an entity.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec fields(entity_selector()) :: %{atom() => field()}
  def fields(entity) do
    Map.new(Map.fetch!(@fields, entity(entity)), fn {name, wire, format, type} ->
      {name,
       %{
         name: name,
         wire: wire,
         format: format,
         type: type,
         since: "3.3",
         nullable: type == :nullable_integer
       }}
    end)
  end

  @doc """
  Returns field metadata, or nil for a field outside the schema.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec field(entity_selector(), atom()) :: field() | nil
  def field(entity, name), do: Map.get(fields(entity), name)

  @doc """
  Returns each relation's cardinality and target entity.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec relations(entity_selector()) :: %{atom() => relation()}
  def relations(entity), do: Map.fetch!(@relations, entity(entity))

  @doc """
  Returns a relation's explicit stable wire name.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec relation_wire(atom()) :: String.t()
  def relation_wire(name), do: Map.fetch!(@relation_names, name)

  @doc """
  Returns the portable operators allowed by a scalar field's value category.

  See the [worked example](api-examples.html#local-graph-and-filtering).
  """
  @spec operators(field()) :: [operator()]
  def operators(%{type: type}) do
    [:equals, :not, :in, :not_in] ++
      case type do
        type when type in [:integer, :nullable_integer] -> [:lt, :lte, :gt, :gte]
        :string -> [:contains, :starts_with, :ends_with]
        _ -> []
      end
  end

  @doc false
  def valid_value?(%{nullable: true}, nil), do: true

  def valid_value?(%{type: type}, value) when type in [:integer, :nullable_integer],
    do: is_integer(value) and value in 0..2_147_483_647

  def valid_value?(%{type: :boolean}, value), do: is_boolean(value)

  def valid_value?(%{type: :string}, value),
    do: is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  def valid_value?(%{type: {:id, :window_link}}, {_session, index, _window} = value),
    do:
      is_integer(index) and index in 0..2_147_483_647 and
        match?({:ok, _}, LibTmux.Ref.new(:window_link, value, "schema"))

  def valid_value?(%{type: {:id, :window_link}}, _value), do: false

  def valid_value?(%{type: {:id, entity}}, value),
    do: match?({:ok, _}, LibTmux.Ref.new(entity, value, "schema"))

  def valid_value?(_field, _value), do: false
end
