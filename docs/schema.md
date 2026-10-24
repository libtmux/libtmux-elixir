# Observation and filter schema

Generated from `LibTmux.Schema`; regenerate with `mix run scripts/generate_schema.exs`.
All current fields use the tmux 3.3 capture baseline. Coverage must still be loaded.
Only `nullable_integer` admits `nil`; other unavailable or unloaded fields raise.
Link IDs are `{session_id, index, window_id}` locally and three-element arrays on the wire.
See [filtering](filtering.md) for Boolean, relation and error semantics.

## `session`

| Elixir field | Wire field | Value category | tmux format | Operators |
| --- | --- | --- | --- | --- |
| `attached` | `attached` | `:boolean` | Derived | `equals`, `not`, `in`, `not_in` |
| `attached_count` | `attachedCount` | `:integer` | `session_attached` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `id` | `id` | `{:id, :session}` | `session_id` | `equals`, `not`, `in`, `not_in` |
| `name` | `name` | `:string` | `session_name` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |

| Relation | Wire relation | Cardinality | Target | Operators |
| --- | --- | --- | --- | --- |
| `active_window` | `activeWindow` | `one` | `window` | `is`, `is_not` |
| `clients` | `clients` | `many` | `client` | `some`, `every`, `none`, `count` |
| `panes` | `panes` | `many` | `pane` | `some`, `every`, `none`, `count` |
| `window_links` | `windowLinks` | `many` | `window_link` | `some`, `every`, `none`, `count` |
| `windows` | `windows` | `many` | `window` | `some`, `every`, `none`, `count` |

## `window`

| Elixir field | Wire field | Value category | tmux format | Operators |
| --- | --- | --- | --- | --- |
| `height` | `height` | `:integer` | `window_height` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `id` | `id` | `{:id, :window}` | `window_id` | `equals`, `not`, `in`, `not_in` |
| `layout` | `layout` | `:string` | `window_layout` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `name` | `name` | `:string` | `window_name` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `width` | `width` | `:integer` | `window_width` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `zoomed` | `zoomed` | `:boolean` | `window_zoomed_flag` | `equals`, `not`, `in`, `not_in` |

| Relation | Wire relation | Cardinality | Target | Operators |
| --- | --- | --- | --- | --- |
| `panes` | `panes` | `many` | `pane` | `some`, `every`, `none`, `count` |
| `sessions` | `sessions` | `many` | `session` | `some`, `every`, `none`, `count` |
| `window_links` | `windowLinks` | `many` | `window_link` | `some`, `every`, `none`, `count` |

## `window_link`

| Elixir field | Wire field | Value category | tmux format | Operators |
| --- | --- | --- | --- | --- |
| `active` | `active` | `:boolean` | `window_active` | `equals`, `not`, `in`, `not_in` |
| `id` | `id` | `{:id, :window_link}` | Derived | `equals`, `not`, `in`, `not_in` |
| `index` | `index` | `:integer` | `window_index` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `session_id` | `sessionId` | `{:id, :session}` | `session_id` | `equals`, `not`, `in`, `not_in` |
| `window_id` | `windowId` | `{:id, :window}` | `window_id` | `equals`, `not`, `in`, `not_in` |

| Relation | Wire relation | Cardinality | Target | Operators |
| --- | --- | --- | --- | --- |
| `session` | `session` | `one` | `session` | `is`, `is_not` |
| `window` | `window` | `one` | `window` | `is`, `is_not` |

## `pane`

| Elixir field | Wire field | Value category | tmux format | Operators |
| --- | --- | --- | --- | --- |
| `active` | `active` | `:boolean` | `pane_active` | `equals`, `not`, `in`, `not_in` |
| `current_command` | `currentCommand` | `:string` | `pane_current_command` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `current_path` | `currentPath` | `:string` | `pane_current_path` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `dead` | `dead` | `:boolean` | `pane_dead` | `equals`, `not`, `in`, `not_in` |
| `exit_status` | `exitStatus` | `:nullable_integer` | `pane_dead_status` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `height` | `height` | `:integer` | `pane_height` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `id` | `id` | `{:id, :pane}` | `pane_id` | `equals`, `not`, `in`, `not_in` |
| `index` | `index` | `:integer` | `pane_index` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `pid` | `pid` | `:nullable_integer` | `pane_pid` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `title` | `title` | `:string` | `pane_title` | `equals`, `not`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `width` | `width` | `:integer` | `pane_width` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `window_id` | `windowId` | `{:id, :window}` | `window_id` | `equals`, `not`, `in`, `not_in` |

| Relation | Wire relation | Cardinality | Target | Operators |
| --- | --- | --- | --- | --- |
| `window` | `window` | `one` | `window` | `is`, `is_not` |

## `client`

| Elixir field | Wire field | Value category | tmux format | Operators |
| --- | --- | --- | --- | --- |
| `control_mode` | `controlMode` | `:boolean` | `client_control_mode` | `equals`, `not`, `in`, `not_in` |
| `height` | `height` | `:nullable_integer` | `client_height` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `id` | `id` | `{:id, :client}` | `client_name` | `equals`, `not`, `in`, `not_in` |
| `pid` | `pid` | `:integer` | `client_pid` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `session_id` | `sessionId` | `{:id, :session}` | `session_id` | `equals`, `not`, `in`, `not_in` |
| `width` | `width` | `:integer` | `client_width` | `equals`, `not`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |

| Relation | Wire relation | Cardinality | Target | Operators |
| --- | --- | --- | --- | --- |
| `session` | `session` | `one` | `session` | `is`, `is_not` |
