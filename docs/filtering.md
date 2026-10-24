# Filter captured values

Obtain one [snapshot](observations.md), then select its observed panes:

```elixir
alias LibTmux.{Selection, Snapshot}

editors =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(active: true, current_command: [in: ["nvim", "vim"]])

Enum.map(editors, & &1.id)
```

Selections retain their immutable graph and order. Enumerable delegates to
the materialized list, including suspension and early halt. `size/1` uses
the cached count; ordinary `Enum.member?/2` compares elements. Use
`Selection.member_id?/2` for native ID membership. Enumeration performs no I/O.

`Selection.filter/2` accepts only unary functions and uses Enum truthiness.
Predicate exceptions propagate. `where/2` accepts validated data: keywords
are shorthand for maps, with duplicate keys rejected at every nesting level.
Both validate before scanning, including when no items remain.

`one/2` returns `{:ok, item}` or a structured `:no_match` / `:multiple_matches`
error. `one_or_nil/2` permits zero matches. Their bang variants raise the
same error; both stop at the second match. `exists?/2` stops at its first
match. `count/2` counts matching items; `size/1` returns the cached total.

## Predicate grammar

A bare scalar means equality. Explicit `%{equals: value}` is equivalent.
The [generated schema](schema.md) lists each field's type and operators.
Numbers compare numerically, strings compare case-sensitively without
normalization, and nullable numeric ordering against known nil is false.
`not` negates equality; `not_in` negates membership, including known nil.
Portable regex is not supported. Native predicates may use `Regex` directly.

Fields in one object conjoin. Boolean `and` and `or` accept lists of
criteria; `not` accepts one criteria object. Empty `and` is true and empty
`or` is false. Normalization never combines separate relation quantifiers:

```elixir
alias LibTmux.{Selection, Snapshot}

Selection.where(Snapshot.sessions(snapshot), %{
  panes: %{some: %{active: true, current_command: "nvim"}}
})
```

That predicate requires one pane to satisfy both conditions. Two separate
`some` clauses can match different panes. `every` and `none` are true for
a known-empty relation; `some` is false. `count` counts that relation's
identities: physical windows/panes deduplicate, window links retain memberships.

To-one `is: criteria` is false for known absence and `is_not` negates it.
`is: nil` means absent; `is_not: nil` means present. Session `active_window`
is derived from a complete link domain and loaded active flags. Zero active
links means known absence; multiple active links raise `:ambiguous_relation`.
An unresolved active target remains unloaded. Coverage checks run before
evaluation, including fields behind a Boolean branch that cannot match.

## External filters

`Filter.new/3` returns a validated portable value, and `new!/3` raises its
structured error. Applying that value retains its constructor validation;
explicit new limits validate the normalized tree without generating extra
criteria objects. Prepared predicates may contain
sets and closures; portable filters contain data only.

`Filter.from_json/3` uses built-in JSON and rejects duplicate keys before
map conversion, trailing data and unknown names. `from_wire/3` accepts an
already decoded map; that map cannot reveal discarded duplicate keys.
Neither decoder creates atoms from external keys. Encode through
`Filter.to_wire/1`, then `JSON.encode!/1`.

```json
{"version":1,"entity":"pane","where":{"active":true,"currentCommand":{"in":["nvim","vim"]}}}
```

Default ceilings are 65,536 bytes, depth 16, 1024 value nodes, 256 array
elements and 8192 bytes per string. Wire depth starts at root zero and
counts every member/element; the ceiling is inclusive. Positive integer
options `max_bytes`, `max_depth`, `max_nodes`, `max_list` and
`max_string_bytes` can narrow or widen the constructor budget. JSON object
members have a fixed ceiling of 256. Native input depth counts criteria
objects and also bounds the normalized tree. A normalized conjunction does
not add relation/Boolean nesting; disjunctions, negations and relation
children do. Wire budgets additionally cover the full versioned envelope.
Errors carry the affected path, including Boolean and membership indexes;
early parser-limit errors can identify the root before a path is available.

Selections and filters operate on captured values. Server query planning
and pushdown remain under implementation.
