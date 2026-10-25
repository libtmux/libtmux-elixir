# Read values, execute explicitly

Capture once when several decisions should use the same observed graph.
Keep that snapshot while selecting and filtering. Execute a new command
explicitly when you need another observation or an effect.
Capture records an interval; fields can change during it. The resulting
value stays fixed while live objects continue changing.

## The values you hold

| Value | What it represents | I/O boundary |
| --- | --- | --- |
| `LibTmux.Server` | Executable, socket and environment for an existing server | Pure descriptor construction |
| `LibTmux.Snapshot` | An indexed graph captured over one interval | `LibTmux.Server.snapshot/2` captures a new value |
| `LibTmux.Selection` | Ordered items and their originating snapshot | Filtering and enumeration use captured values |
| `LibTmux.Ref` | An observed exact ID and server instance | Pure identity data; it reserves nothing |
| `LibTmux.Control` | A handle pinned to one connection epoch | Status reads are local; startup explicitly attaches a client |
| `LibTmux.Operation` | Access to one retained operation record | Result/status reads are local; awaiting registers a separate waiter |

Windows are physical objects. `LibTmux.WindowLink` supplies their membership
in a session, index and active state. A linked window can appear more than
once while its panes remain the same physical panes. Choose window links
when membership matters; choose panes when an action should address each
physical pane once. See [captured state](observations.md).

## Coverage tells you which questions the graph can answer

A loaded field may contain a value, an empty string or a documented `nil`.
`:unloaded` means this snapshot does not contain the observation.
`:unavailable` means the capability is absent. Neither means known absence.

Relationship predicates need complete captured join domains. A missing pane
relation cannot satisfy “no pane matches.” Validation raises a structured
coverage error before filtering, including an empty selection. Obtain a new
snapshot explicitly when more coverage is needed. Existing selections retain
their original graph. See [filtering](filtering.md).

## Server identity and connection epochs have different lifetimes

A server instance identifies one tmux process incarnation. Native object IDs
can be reused after that process exits. References retain the observed
instance so qualified control requests can reject known stale targets.
One-shot commands retain a check/use race; an observed ID reserves nothing.

An epoch identifies one control connection and its owned transport actors.
`LibTmux.Control.reconnect/2` obtains the ready epoch and returns it unchanged
when it is already ready. Close first to require a replacement. Replacement
waits for retirement and returns a new pinned handle. The server instance
can stay the same while the epoch changes. Old connection handles cannot
submit into the replacement. Reconnect never replays work.

## Waiting, command outcomes and retirement are separate

| Result | What the caller can conclude |
| --- | --- |
| `LibTmux.Control.submit/3` returns `{:ok, operation}` | Admission succeeded; inspect or await the retained operation |
| `LibTmux.Operation.await/2` returns an API timeout | This waiter ended; the operation may still advance |
| A canonical outcome is `:completed` or `:failed` with `:acknowledged` certainty | tmux supplied a command reply; arbitrary programs started by that command have their own lifetimes |
| A canonical outcome is `:skipped` with `:no_write` certainty | The operation was classified before dispatch |
| A canonical outcome is `:unknown` | Available evidence cannot determine its effects |
| Operation status reports `wire: :retired` | Reply attribution has retired; the retained record may still occupy capacity |
| `LibTmux.Control.close/2` returns `:ok` | The pinned connection epoch retired; its enclosing supervisor remains running |

Each await call has its own budget. Timeout or caller death ends that waiter
without cancelling the operation. For wire-active work,
`LibTmux.Operation.stop/1` requests closure of the entire pinned epoch and can
affect siblings. An already retired operation returns `:ok` without closing
its connection. Use `LibTmux.Control.close/2` to wait for connection retirement.
Inspect retained results instead of replaying an uncertain mutation.

Once a canonical outcome exists, it stays unchanged. Bang operation APIs
raise API/context errors and still return canonical failed, skipped and
unknown outcomes as values. Wire retirement, record expiry and native process
cleanup each have their own evidence. See [ownership](ownership.md) for
deadlines, bounds and the remaining qualification limits.

## Return conventions

These APIs answer different questions. Command completion does not mean
a program started by tmux has finished.

| API | Normal return | Failure handling |
| --- | --- | --- |
| Domain actions such as `LibTmux.Window.rename/4` | `{:ok, result}` only for completion, retaining value and evidence | Unsuccessful outcomes use `LibTmux.Action.CompletionError`; API and admitted execution errors retain their own types |
| Domain bangs such as `LibTmux.Window.rename!/4` | Completed value | Raise the same errors with their evidence |
| `LibTmux.Control.execute/3` and `LibTmux.Operation.await/2` | `{:ok, canonical_result}`, including failed, skipped and unknown outcomes | Outer errors describe execution context or waiting; their bangs raise those errors and return canonical outcomes unchanged |
| `LibTmux.Selection.one/2` and `LibTmux.Selection.one_or_nil/2` | `{:ok, item}`, or allowed `{:ok, nil}` | Cardinality errors are tuples; bangs raise them. Predicate and coverage validation can raise in either form |
| Relationship helpers such as `LibTmux.Session.panes/2` | Ordered selection, or observation/nil for to-one relationships; no I/O | Identity, coverage and ambiguity errors raise |
| `LibTmux.Control.with_connection/2` | `{:ok, callback_value}` after cleanup, even when that value is `{:error, reason}` | Startup errors return errors; callback raise/throw/exit propagates after cleanup. Unproved cleanup returns `LibTmux.Control.ScopeFailure` preserving the primary outcome |

The [recovery example](recovery.md) handles lower-level execution and cleanup
separately. Option validation may raise; a nonbang name does not promise that
every malformed call returns an error tuple.
