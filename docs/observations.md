# Captured tmux state

- `LibTmux.Server.new/1` builds a descriptor with an explicit executable and a
  socket choice. The choice is a path, a name, one of `LIBTMUX_SOCKET_PATH` and
  `LIBTMUX_SOCKET`, or none, which leaves it to tmux. It does no I/O.
- `LibTmux.Server.snapshot/2` observes that existing server and returns an
  immutable `LibTmux.Snapshot`.
- Neither call attaches a control client or starts a missing server.
- Configured tmux hooks remain environmental effects of commands, including
  list commands.

## Read one captured graph

- `Snapshot.items/2` returns a plain list for an entity atom or module.
- `Snapshot.fetch/3` looks up an exact ID.
- `Snapshot.related/4` follows captured indexes, and raises a structured
  coverage error when a relation is incomplete.
- `Snapshot.sessions/1`, `windows/1`, `panes/1`, `window_links/1` and
  `clients/1` return materialized selections.
- None of these does I/O. See [filtering](filtering.md) for local predicates
  and portable criteria.

For common relationships, pass the snapshot and a session or window
observation to `Session.windows/2`, `Session.panes/2`, `Session.active_window/2`
or `Window.panes/2`:

- The plural helpers return selections for filtering and checked cardinality
  with `LibTmux.Selection`. `active_window/2` returns a window or `nil`.
- They validate the observation's kind, ID and server incarnation, then use
  the supplied graph's fields and coverage. An older observation from the same
  incarnation is valid, and its other fields are ignored.
- Each selection keeps the supplied graph. `Enum.to_list/1` gives a plain list
  without it.
- Direct traversal validates only the requested source. One session's active
  window does not fail because another session has ambiguous active links.
- Relationship filters validate their whole captured source domain before
  iteration, even when the selection is empty.

Sessions, physical windows, panes and clients have separate maps:

- A pane belongs to one physical window.
- `WindowLink` records session membership, window index and active state. Its
  key is session ID, index and window ID, which does not prove a unique
  lifetime after unlink and relink.
- A window can appear at several indexes in one session, and in other
  sessions. Server-wide physical maps deduplicate identical rows and reject
  conflicting rows.
- Session pane traversal returns each physical pane once. Window-link
  traversal keeps memberships.
- Sessions, windows and panes sort by numeric native ID. A session's windows
  follow their first link's index; its panes sort by numeric pane ID. Links
  sort by numeric session ID and index. Clients sort bytewise by observed
  name.

Field notes:

- `Session.attached_count` keeps tmux's raw client count, and `attached` is
  derived from it. Control clients stay counted even with `no-output` and
  `ignore-size`.
- A control client's height is known `nil` when tmux reports no started tty.
  It is not an unavailable field.
- `Pane.pid` is known `nil` when tmux reports no PID, including empty and
  retained dead panes on tmux 3.8. Other values stay as reported: older tmux
  can report zero for an empty pane, or a historical PID for a dead one.
  Neither a PID nor its absence proves a process is alive or cleaned up.

## Coverage and construction

- `Snapshot.new/2` validates fixture or adapter observations without I/O.
- `fields` declares loaded fields over the supplied entity IDs. `complete`
  declares complete server entity sets; omissions stay partial. `unavailable`
  declares absent capabilities separately.
- Declared names and values validate before indexes or relations become
  observable.
- Known empty strings, known nullable values, `:unloaded` and `:unavailable`
  stay distinct. Required coverage checks run even for empty entity sets.
- Derived attachment coverage follows its source count.
- A relation to many objects needs a complete join domain, so missing
  children never become an empty relation. Complete target sets reject
  dangling references. A partial target set can keep unresolved foreign IDs,
  but traversal fails explicitly.

The [generated schema](schema.md) owns field types, wire names, tmux variables
and relation cardinalities. Physical windows carry no single session, session
index or active membership flag.

## Capture consistency and bounds

- Capture reads topology, then named fields, then topology again. It checks
  the tmux PID against Linux boot identity and process start ticks before and
  after those reads.
- A replaced server or changing references trigger finite read retries, as
  does a disappearing read target. Invalid encoding and other decoding errors
  stay visible.
- Two attempts are the default; request one to three. All attempts share one
  deadline and the original budgets.
- Defaults: 1024 contextual topology rows, 512 commands, 8 MiB total response
  bytes, 64 KiB per response and 5000 ms.
- Stdout and stderr both consume the byte budget, including failed-command
  output. Overload returns an error, not a truncated success.
- Topology checks and retries also consume work. An overflowing text listing
  can fall back to individual reads, as [capture rows](encoding.md#capture-rows)
  describes, and that work stays charged to the original budgets.
- One-shot retirement has a separate allowance; see [ownership](ownership.md).

Encoding:

- Free-form fields use the qualified versioned encoder. Numeric and ID
  topology columns validate their whole representation.
- Client rows combine one encoded identity with restricted scalar columns, so
  tabs and newlines cannot escape the identity.
- This is a fixed capture schema, not a general raw-format row parser.

A capture records an observation, not a transaction:

- Attributes can change within the interval. Matching topology before and
  after does not prove nothing changed in between.
- Holding a snapshot reserves no objects.
- Its server instance differs from a future connection epoch, and one-shot
  checks keep a check/use race.
- Sending a snapshot between BEAM processes can copy terms, and keeping one
  keeps its graph.
