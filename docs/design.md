# Design and remaining work

The core implements immutable observations, indexed filters, bounded capture,
one-shot execution, persistent control and explicit domain actions. This page
preserves constraints for that implementation and for the remaining Query,
Tracker, planner, workspace and MCP work; it is not a claim that those planned
components exist.
The [implementation contracts](implementation.md) map those responsibilities
to package boundaries and qualification gates.

## Values and explicit observation

Use Elixir `1.20.x` (at least `1.20.4`) and OTP `29.x` as the development
toolchain, and tmux `3.3` as the compatibility floor. Keep the core
free of third-party runtime dependencies. Use
[standard-library JSON][elixir-json] and OTP processes where their contracts
fit; development dependencies are separate.

The initial declared OTP support minimum is `29.1.2`; the floating
development selector does not establish support for older OTP 29 releases.

| Responsibility | Status and contract |
| --- | --- |
| Snapshot | Implemented: immutable graph, capture interval, server identity, and coverage |
| Selection | Implemented: ordered materialized values implementing `Enumerable`; no hidden I/O |
| Filter | Implemented: validated portable criteria; native Elixir predicates remain local code |
| Query | Planned: explicit source plan; execution occurs at fetch, not enumeration |
| Tracker | Planned: optional supervised owner of retained snapshots with visible status and bounded refresh |

Model physical windows separately from session window links. Pane identity
belongs to a physical window; session-relative index and active state belong
to the link. Preserve attached-client counts. Distinguish absent values,
unloaded relations, and unavailable fields before evaluating a filter.

Native callers use pattern matching, `Enum`, comprehensions, and functions.
Portable criteria serve saved queries and external callers; payload keys use
an explicit whitelist and bounded decoding. Query optimizations must retain
every possible match and apply the full filter locally against required
coverage. Keeping observations immutable does not make capture atomic.

## Connections and operations

Processes own connections and operation lifetimes, not individual model
objects. Keep protocol framing and command encoding pure and separate from
transport. A one-shot transport and a persistent control transport have
different attachment and cleanup costs; make their selection explicit.

Control clients are visible to tmux and
[affect attachment accounting][attachment-counts]. Do not create a session
or attach merely to read a local value. Bind strong target
identity to a qualified server connection; disconnects and cancellation can
leave a mutation's result uncertain. Never silently replay such a mutation
or fall back to a positional target.

The planned batch/group/dependency surfaces retain these distinctions.
An independent batch preserves separate command results. A semicolon group
[stops at a runtime error][command-groups], leaving an applied prefix and
skipping its suffix.
A dependency plan uses prior results, including created IDs. None of these
implies rollback or ACID transactions.
[Command acknowledgement][command-guards], operation completion, and
observation of the result are separate events.

## Retained state and output

The planned optional Tracker reuses Snapshot rather than defining another graph.
Retained reads perform no tmux command and report loading, ready, stale, or
disconnected status. Refresh is explicit and bounded. Updates carry their
connection epoch so late results cannot modify a replacement connection.

[Notifications][notifications] cover only some changes;
[format subscriptions][format-subscriptions] sample values.
Only qualified, [line-safe subscriptions][subscription-values] may update
authoritative state; free-form values require a proven encoding or explicit
capture. Reconcile missing coverage within finite work and buffer budgets.

Bound output retention and delivery, report gaps, and register observation
before the action it must cover. tmux [flow control][flow-control] does not
provide automatic backpressure for Erlang subscriber mailboxes. A timeout
does not prove that an already-dispatched command had no effect.

## Package and validation boundaries

Workspace loading and MCP are separate packages that depend on the core.
The core does not depend on their parsers, hosting, or configuration. The
[implementation contracts](implementation.md#packages-and-support) select
the package names and layout; adapter dependency choices still require
qualification.

Implementation must establish parser and quoting behavior, real-tmux
compatibility, completion and cancellation semantics, bounded resource
ownership, and package consumption outside the checkout. Documentation must
use examples that execute those contracts. Current checks exercise implemented
core behavior, including native retirement and packaged callers; they do not
qualify planned consumers or unexercised operations. See the
[contribution guide](../.github/CONTRIBUTING.md) for validation scope.

The tmux links point to the 3.3 source commit, matching the compatibility floor.

[elixir-json]: https://hexdocs.pm/elixir/1.20.4/JSON.html
[attachment-counts]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/resize.c#L439-L461
[command-groups]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-queue.c#L765-L783
[command-guards]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-queue.c#L663-L669
[notifications]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/notify.c#L172-L218
[format-subscriptions]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/control.c#L1033-L1063
[subscription-values]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/control.c#L902-L943
[flow-control]: https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/control.c#L358-L463
