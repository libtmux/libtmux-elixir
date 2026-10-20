defmodule LibTmux.Schema do
  @moduledoc """
  Defines observed fields, wire names and graph relations.

  The table is a semantic overlay on tmux 3.3 format variables. It drives
  observation validation and later filter/reference generation. Empty text
  remains text; only explicitly nullable fields admit `nil`.
  """

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
      {:pid, "pid", "pane_pid", :integer},
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

  @doc "Returns supported entity names in a stable order."
  def entities, do: @entities

  @doc "Returns the ordinary observation struct module for an entity."
  def module(entity), do: Map.fetch!(@modules, entity)

  @doc "Resolves an entity atom or its observation module."
  def entity(entity) when entity in @entities, do: entity

  def entity(module),
    do:
      Enum.find_value(@modules, fn {entity, value} -> if value == module, do: entity end) ||
        raise(ArgumentError, "unknown entity")

  @doc "Returns the whitelisted field metadata for an entity."
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

  @doc "Returns field metadata, or nil for a field outside the schema."
  def field(entity, name), do: Map.get(fields(entity), name)

  @doc "Returns each relation's cardinality and target entity."
  def relations(entity), do: Map.fetch!(@relations, entity(entity))

  @doc false
  def valid_value?(%{nullable: true}, nil), do: true

  def valid_value?(%{type: type}, value) when type in [:integer, :nullable_integer],
    do: is_integer(value) and value in 0..2_147_483_647

  def valid_value?(%{type: :boolean}, value), do: is_boolean(value)

  def valid_value?(%{type: :string}, value),
    do: is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  def valid_value?(%{type: {:id, entity}}, value),
    do: match?({:ok, _}, LibTmux.Ref.new(entity, value, "schema"))

  def valid_value?(_field, _value), do: false
end
