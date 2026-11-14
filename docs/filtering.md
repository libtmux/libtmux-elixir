# Filter captured values

Capture one [snapshot](observations.md), then select from it. Run the
examples on a private server with the [owned-server runner](owned-server.md):

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/filtering.exs
```

<!-- example: examples/filtering.exs#where -->

```elixir
alias LibTmux.{Selection, Server, Snapshot}

[executable, socket, session_id] = System.argv()

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

snapshot = Server.snapshot!(server)

active =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(active: true, current_command: [in: ["cat", "nvim", "vim"]])

Enum.map(active, & &1.id)
```

<!-- /example -->

- Selections keep their graph and order. Enumerating one does no I/O.
- `size/1` reads a cached count.
- `Enum.member?/2` compares elements; `Selection.member_id?/2` compares
  native IDs.

## Select

- `where/2` takes validated data. Keywords are shorthand for maps, and
  duplicate keys are rejected at every level.
- `filter/2` takes a unary function and uses `Enum` truthiness. Predicate
  exceptions propagate.
- Both validate before scanning, even when no items remain.
- `one/2` returns `{:ok, item}` or a structured `:no_match` or
  `:multiple_matches` error. `one!/2` raises the same error.
- `one_or_nil/2` also allows zero matches. Both stop at the second match.
- `exists?/2` stops at the first match. `count/2` counts matches; `size/1`
  returns the total.

## Predicate grammar

- A bare scalar means equality; `%{equals: value}` is the same. The
  [generated schema](schema.md) lists each field's type and operators.
- Numbers compare numerically and strings compare case-sensitively, with no
  normalization. Ordering a nullable number against a known `nil` is false.
- `not` negates equality. `not_in` negates membership, including known `nil`.
- Portable regex is not supported. Native predicates may use `Regex`.
- Fields in one object conjoin. `and` and `or` take lists of criteria and
  `not` takes one criteria object. An empty `and` is true; an empty `or` is
  false.
- Separate relation quantifiers are never combined:

<!-- example: examples/filtering.exs#relation -->

```elixir
alias LibTmux.{Selection, Snapshot}

with_cat =
  Selection.where(Snapshot.sessions(snapshot), %{
    panes: %{some: %{active: true, current_command: "cat"}}
  })

```

<!-- /example -->

That predicate needs one pane to satisfy both conditions. Two separate `some`
clauses can match different panes.

- `every` and `none` are true for a known-empty relation; `some` is false.
- `count` counts the relation's identities. Physical windows and panes
  deduplicate; window links keep their memberships.
- To-one `is: criteria` is false for known absence, and `is_not` negates it.
  `is: nil` means absent; `is_not: nil` means present.
- A session's `active_window` comes from a complete link domain and loaded
  active flags. Zero active links is known absence; several raise
  `:ambiguous_relation`. An unresolved active target stays unloaded.
- Coverage checks run before evaluation, including fields behind a Boolean
  branch that cannot match.

## External filters

- `Filter.new/3` returns a validated portable value; `new!/3` raises its
  structured error. Applying the value keeps its constructor validation.
- Prepared predicates may hold sets and closures. Portable filters hold only
  data. `LibTmux.Filter.to_predicate/2` reuses a filter as a predicate.
- `Filter.from_json/3` uses built-in JSON. It rejects duplicate keys,
  trailing data and unknown names.
- `from_wire/3` takes an already decoded map, which cannot show discarded
  duplicate keys.
- Neither decoder creates atoms from external keys.
- Encode with `Filter.to_wire/1`, then `JSON.encode!/1`.

<!-- example: examples/filtering.exs#wire -->

```elixir
alias LibTmux.{Filter, Pane}

{:ok, filter} = Filter.new(Pane, active: true, current_command: [in: ["nvim", "vim"]])
json = filter |> Filter.to_wire() |> JSON.encode!()
{:ok, ^filter} = Filter.from_json(Pane, json)
```

<!-- /example -->

The document is:

```json
{"version":1,"entity":"pane","where":{"active":true,"currentCommand":{"in":["nvim","vim"]}}}
```

## Limits

Defaults: 65,536 bytes, depth 16, 1024 value nodes, 256 array elements and
8192 bytes per string. Positive integer options `max_bytes`, `max_depth`,
`max_nodes`, `max_list` and `max_string_bytes` narrow or widen them.

- A JSON object has at most 256 members.
- Wire depth starts at root zero and counts every member and element. The
  ceiling is inclusive.
- Native input depth counts criteria objects and bounds the normalized tree.
  A normalized conjunction adds no relation or Boolean nesting; disjunctions,
  negations and relation children do.
- Wire budgets also cover the versioned envelope.
- Errors carry the affected path, including Boolean and membership indexes.
  An early parser-limit error can name only the root.

Filters run locally on a captured snapshot. Server-side query planning is not
implemented.
