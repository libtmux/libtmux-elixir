# Implementation contracts

This page records the selected implementation boundaries. Features remain
planned until their public contracts and checks exist. See [design](design.md)
for the observation and execution model.

## Packages and support

The root project owns the `libtmux` Hex package and `LibTmux` namespace.
`packages/workspace` owns `libtmux_workspace` and `LibTmux.Workspace`;
`packages/mcp` owns `libtmux_mcp` and `LibTmux.MCP`. Each is an ordinary Mix
project. Published consumer metadata uses a real core version requirement.
Explicit development wiring may select the local core, but installed checks
must use packed artifacts outside this repository. Core has no third-party
runtime dependencies and never imports a consumer package.
MCP also consumes the workspace package for workspace tools; it must not
duplicate the loader, planner or apply journal.

Workspace and MCP initially distribute escripts with Elixir embedded by
Mix. Running an escript requires the supported OTP runtime, while building
it requires the supported Elixir toolchain. ERTS is not bundled. A later
Mix release is an additional choice, subject to installed-consumer checks.

The implementation targets Elixir 1.20.4 or newer patches in the 1.20 line,
OTP releases at or above 29.1.2 and below 30, and tmux 3.3 or newer. These are
intended support contracts; current scaffold checks do not establish them.
The development selectors remain `elixir 1.20` and `erlang 29`. Resolve the
selected Elixir build for OTP 29 and record its compiled/runtime identity.
The selectors do not expand the tested support range to OTP 29.0.

[The support manifest](../priv/tmux/support.json) records exact reference
cells and tmux source revisions. Required Linux cells are tmux 3.3, 3.3a,
3.4 and 3.8 on Elixir 1.20.4/OTP 29.1.2, plus the resolved development
pair. Add versions when an introduced feature or regression needs its own
evidence. macOS remains optional. Missing required prerequisites fail a
required cell; they cannot become successful skips.

## Public responsibilities

| Surface | Contract and critical proof |
| --- | --- |
| `Server` | Explicit executable/socket/environment and transport. Connect does not create a server. Close releases owned clients without killing borrowed sessions. |
| `Session`, `Window`, `WindowLink`, `Pane`, `Client` | Typed immutable observations with exact IDs. Link context belongs to WindowLink. Preserve counts and reject conflicting repeated physical rows. |
| `Snapshot` | Indexed graph, incarnation, capture interval and scoped coverage. Differentiate unloaded, unavailable, known nil, empty and invalid data. Capture validates references with bounded retry. |
| `Selection` | Ordered materialized Enumerable, cached size, ordinary element equality, no I/O. Data filtering and native predicates have separate entrypoints. Checked cardinality stops at the second match. |
| `Filter` | Validated portable data, keyword/map normalization, correlated relations, explicit wire names and path errors. No atom creation or implicit regex dialect. |
| `Query` | Non-enumerable plan with explicit fetch. Explain coverage, identity, order, attachment effects and error-equivalence status. |
| `Command` and `Format` | Distinct argv, tmux syntax and format encoding. Raw syntax is a trusted escape hatch and cannot silently enter a reusable qualified lane. |
| `Batch`, `Group`, `Plan` | One command representation with stable node IDs. Independent continue-on-error, ordered fail-fast and output dependencies remain distinct. |
| `Operation` | Bounded admission and retained inspection, one caller settlement, one final node classification and separate wire retirement. |
| `Observation` | Explicit registration before action, bounded retention/demand and cursor/gap semantics. Capture is separate screen state. |
| `Tracker` | Optional owner of the same Snapshot graph. Retained reads expose status and never refresh or wait for readiness. |
| Owned runner | Explicit argv/cwd/environment, gated execution and private completion channel; no inferred program exit from interactive pane text. |
| `Workspace` | Versioned JSON loader and real CLI, read-only planning, exact preconditions, explicit apply and partial journal. |
| `MCP` | STDIO discovery and bounded retained operations under host authority. Models choose allowlisted server IDs and exact returned references. |

Server/session/window/pane/client operations also cover options, hooks and
formats. Preserve server/session/window scope and local/inherited/effective
option distinctions. Literal text and named keys are different operations.
Configured hooks and aliases are part of lane qualification; never disable
them silently to make attribution easier.

## Ownership and failure

Use supervised OTP processes around connection epochs and operation
lifetimes. One epoch owns its writer/parser/router subtree; the final writer
checks epoch and operation identity immediately before sending. A dead
epoch cannot admit more work or lend its writer to a replacement. Reconnect
does not replay queued or uncertain mutations.

A caller can settle while the operation continues gathering evidence.
Routing capacity is reusable only after wire retirement. Finish a partially
written line under its original owner or close the epoch before writing
anything else. A group error can remove suffix commands without reply
blocks; use a separately attributable fence or retire the lane. Preserve
aggregate output and unknown attribution when individual results are unproved.

Strong incarnation-bound mutation requires an existing qualified live
connection. Never fall back to one-shot or replacement-connection execution.
One-shot identity checks expose their remaining check/use race. Exact IDs
never fall back to positions when an object disappears.

Convert each positive millisecond timeout once into a monotonic budget for
queueing, writes, replies and required proof. One error envelope carries
kind, phase, certainty, retryable, path and bounded details/partial results.
Bang APIs raise that same error. Retryable never authorizes mutation replay.
Command acknowledgement does not prove external process completion.

Bound parser carry, frames, queues, Port delivery, BEAM mailboxes, captures,
stderr, pending calls and retained results together. A later bounded queue
does not fix an upstream unbounded mailbox. The standard-library transport
must qualify flood/slow-reader behavior, owner/VM death and descendant exit.
A runtime dependency remains outside the core contract unless the user
separately approves a measured critical exception.

## Capture, filtering and observation

Start with a bounded conservative codec: one free-form field per subprocess
response, removing only its one framing newline. Restricted ID/numeric
fields may share a validated format. US/RS with tmux `q` is not a safe
delimiter scheme. A more efficient encoding must first pass hostile-byte
round trips at every required release. Never decode quoting by shell evaluation.

Selection validation checks fields, types and required coverage before
iteration, including empty selections. Local callbacks keep Enum truthiness
and ordinary exceptions. Filter data preserves Boolean identities,
some/every/none correlation, optional to-one semantics and relation counts.
Reject duplicate keyword keys recursively. External JSON has whitelisted
names and finite byte/depth/node/list budgets, rejects trailing data, and
rejects duplicate keys before map conversion loses them.

Query reference execution captures required coverage and evaluates locally.
Pushdown is enabled only where both necessary-condition implication and
observable decode/validation/coverage error equivalence are qualified.
Capture complete relations independently from candidate root filtering.
Apply residual predicates before contextual deduplication, order and limit.
Unsupported optimizations retain reference behavior.

Authoritative subscriptions require complete expansions proven line-safe
or losslessly encoded for the connected release. Unsafe required fields
fail registration. Only explicitly optional fields may remain untracked.
Opaque raw streams cannot update authoritative state or share command-reply
correlation. Observer scope follows the attached session and attachment
effects require explicit policy.

Do not treat `pause-after` as end-to-end subscriber demand. Keep bounded
retention and explicit gaps on overload, scope loss or reconnect. Tracker
bootstrap/reconciliation has finite time/work/byte budgets. Unknown event
ordering invalidates coverage; stale buffered events cannot overwrite a
newer baseline. Prior-epoch refreshes cannot publish into a new epoch.

## Qualification sequence

The saved implementation epic owns task identity and progress. Its research
approvals do not pass implementation gates. Qualify package/fixture and pure
codec boundaries first, then bounded one-shot capture, local query semantics,
persistent control and domain operations. Batch/planner, observation/runner
and consumer tasks build on those contracts.

The final gates include all required Linux cells, three packed consumers,
executed examples and teardown, rendered ExDoc/reference links, and a complete
shared-site build tied to separate library/exporter identities. Benchmark
the same semantic workload across selected modes only after results/effects
and attribution agree. Record independent architecture and final adoption
reviews with exact inputs and findings.

Shared-site publication stays pending until separately authorized and
externally verified. Package releases require separate authorization.
