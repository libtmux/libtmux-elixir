# Captured tmux state

`LibTmux.Server.new/1` constructs a descriptor with an explicit executable
and a socket choice: a path, a name, one of the `LIBTMUX_SOCKET_PATH` and
`LIBTMUX_SOCKET` variables, or none, which leaves the choice to tmux. It
performs no I/O. `LibTmux.Server.snapshot/2` observes that existing server
and returns an immutable `LibTmux.Snapshot`. Neither call attaches a control
client or starts a missing server. Configured tmux hooks
remain environmental effects of commands, including list commands.

## Read one captured graph

`Snapshot.items/2` returns a plain list for an entity atom or module.
`Snapshot.fetch/3` looks up an exact ID. `Snapshot.related/4` follows captured
indexes and raises a structured coverage error when a relation is incomplete.
These functions perform no I/O. `Snapshot.sessions/1`, `windows/1`, `panes/1`,
`window_links/1` and `clients/1` return materialized Enumerable selections.
See [filtering](filtering.md) for local predicates and portable criteria.

For common relationships, pass the snapshot and a session/window observation
to `Session.windows/2`, `Session.panes/2`, `Session.active_window/2` or
`Window.panes/2`. The plural helpers return selections for filtering and
checked cardinality with `LibTmux.Selection`; `active_window/2`
returns a window or `nil`. They validate the observation's kind, ID and server
incarnation, then use the supplied graph's fields and coverage. An older
observation from the same incarnation is valid; its other fields are ignored.
Each selection retains the supplied graph. Use `Enum.to_list/1` to obtain a
plain list without the graph context.

Direct traversal validates the requested source. Looking up one session's
active window does not fail because another session has ambiguous active
links. Relationship filters validate their entire captured source domain
before iteration, even when the selection is empty.

Sessions, physical windows, panes and clients have separate maps. A pane
belongs to one physical window. `WindowLink` records session membership,
window index and active state. Its key includes session ID, index and window
ID; it does not prove a unique lifetime after unlink and relink.

A window can appear at multiple indexes in the same session and in other
sessions. Server-wide physical maps deduplicate identical rows and reject
conflicting rows. Session pane traversal returns each physical pane once;
window-link traversal preserves memberships. Top-level session/window/pane
collections sort by numeric native ID. Session windows follow their first
link's index; session and window panes sort by numeric pane ID. Links sort
by numeric session ID and index; clients sort bytewise by their validated
observed names.

`Session.attached_count` preserves tmux's raw client count. `attached` is
derived from that count. Explicit control clients remain counted even with
`no-output` and `ignore-size`. A control client's height is known `nil` when
tmux reports no started tty; it is not an unavailable field.

`Pane.pid` is known `nil` when tmux reports no PID, including empty and
retained dead panes on tmux 3.8. Reported integers stay unchanged: older tmux
versions can report zero for an empty pane or a historical PID for a dead
pane. Neither a PID nor its absence proves process liveness or cleanup.

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

Defaults are 1024 contextual topology rows, 512 commands, 8 MiB total response
bytes, 64 KiB per response and 5000 ms. Both stdout and stderr, including
failed-command output, consume the byte budget. Overload returns an error
instead of a truncated success. Topology checks and retries also consume
work. Text listings use the byte and command budgets; an overflowing listing
can fall back to individual reads as described in [capture rows](encoding.md#capture-rows).
That work remains charged to the original budgets. One-shot retirement has the separate allowance documented in
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
