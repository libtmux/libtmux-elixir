# Captured tmux state

`LibTmux.Server.new/1` constructs a descriptor with an explicit executable
and socket. It performs no I/O. `LibTmux.Server.snapshot/2` observes that
existing server and returns an immutable `LibTmux.Snapshot`. Neither call
attaches a control client or starts a missing server. Configured tmux hooks
remain environmental effects of commands, including list commands.

## Read one captured graph

`Snapshot.items/2` returns a plain list for an entity atom or module.
`Snapshot.fetch/3` looks up an exact ID. `Snapshot.related/4` follows captured
indexes and raises a structured coverage error when a relation is incomplete.
These functions perform no I/O. `Snapshot.sessions/1`, `windows/1`, `panes/1`,
`window_links/1` and `clients/1` return materialized Enumerable selections.
See [filtering](filtering.md) for local predicates and portable criteria.

Sessions, physical windows, panes and clients have separate maps. A pane
belongs to one physical window. `WindowLink` records session membership,
window index and active state. Its key includes session ID, index and window
ID; it does not prove a unique lifetime after unlink and relink.

A window can appear at multiple indexes in the same session and in other
sessions. Server-wide physical maps deduplicate identical rows and reject
conflicting rows. Session pane traversal returns each physical pane once;
window-link traversal preserves memberships. Session/window/pane lists sort
by numeric native ID. Links sort by numeric session ID and index; clients
sort bytewise by their validated observed names.

`Session.attached_count` preserves tmux's raw client count. `attached` is
derived from that count. Explicit control clients remain counted even with
`no-output` and `ignore-size`. A control client's height is known `nil` when
tmux reports no started tty; it is not an unavailable field.

## Coverage and construction

`Snapshot.new/2` validates fixture or adapter observations without I/O.
`fields` declares loaded fields over the supplied entity IDs. `complete`
declares complete server entity sets; omissions remain partial. `unavailable`
declares absent capabilities separately. Declared names and values validate
before indexes or relations become observable.

Known empty strings, known nullable values, `:unloaded` and `:unavailable`
remain distinct. Required coverage checks run even for empty entity sets.
Derived attachment coverage follows its source count. A relation to many
objects needs a complete join domain, so missing children never become an
empty relation. Complete target sets reject dangling references. A partial
target set can retain unresolved foreign IDs, but traversal fails explicitly.

The [generated schema](schema.md) owns field types, explicit wire names,
tmux variables and relation cardinalities. Physical windows carry no single
session, session index or active membership flag.

## Capture consistency and bounds

Capture reads topology, then named fields, then topology again. It checks
the tmux PID against Linux boot identity and process start ticks before and
after those reads. Replacement or changing references trigger finite read
retries. A disappearing read target can retry; invalid encoding and other
decoding errors remain visible. Two attempts are the default; one to three
may be requested. All attempts share one deadline and the original budgets.

Defaults are 1024 contextual entity rows, 512 commands, 8 MiB total response
bytes, 64 KiB per response and 5000 ms. Both stdout and stderr, including
failed-command output, consume the byte budget. Overload returns an error
instead of a truncated success. Topology checks and retries also consume
work. One-shot retirement has the separate allowance documented in
[ownership](ownership.md).

Free-form fields use the qualified versioned encoder. Numeric/ID topology
columns validate their complete representation. Client rows combine one
encoded identity with restricted scalar columns; tabs and newlines cannot
escape the encoded identity. This is a fixed capture schema, not a general
raw-format row parser.

The capture interval records observation, not a transaction. Attributes can
change within it; matching topology before and after does not prove nothing
changed in between. Holding a snapshot reserves no objects. Its server
instance is distinct from a future connection epoch, and one-shot checks
retain a check/use race. Sending snapshots between BEAM processes can copy
terms; retaining one can retain its graph.
