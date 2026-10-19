# Planned design

These are implementation constraints for the unpublished scaffold. Module
names describe proposed responsibilities; no tmux API exists yet.

## Values and explicit observation

Use Elixir `1.20.4` and OTP `29.1.2` as the initial reference toolchain, and
tmux `3.3` as the proposed compatibility floor. Keep the core free of
third-party runtime dependencies. Use standard-library JSON and OTP
processes where their contracts fit; development dependencies are separate.

| Responsibility | Planned contract |
| --- | --- |
| Snapshot | Immutable graph, capture interval, server identity, and coverage |
| Selection | Ordered materialized values implementing `Enumerable`; no hidden I/O |
| Filter | Validated portable criteria; native Elixir predicates remain local code |
| Query | Explicit source plan; execution occurs at fetch, not enumeration |
| Tracker | Optional supervised owner of retained snapshots with visible status and bounded refresh |

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

Control clients are visible to tmux and affect attachment accounting. Do not
create a session or attach merely to read a local value. Bind strong target
identity to a qualified server connection; disconnects and cancellation can
leave a mutation's result uncertain. Never silently replay such a mutation
or fall back to a positional target.

An independent batch preserves separate command results. A semicolon group
stops at a runtime error, leaving an applied prefix and skipping its suffix.
A dependency plan uses prior results, including created IDs. None of these
implies rollback or ACID transactions. Command acknowledgement, operation
completion, and observation of the result are separate events.

## Retained state and output

The optional Tracker reuses Snapshot rather than defining another graph.
Retained reads perform no tmux command and report loading, ready, stale, or
disconnected status. Refresh is explicit and bounded. Updates carry their
connection epoch so late results cannot modify a replacement connection.

Notifications and format subscriptions are incomplete, sampled observations.
Only qualified, line-safe subscriptions may update authoritative state;
free-form values require a proven encoding or explicit capture. Reconcile
missing coverage within finite work and buffer budgets.

Bound output retention and delivery, report gaps, and register observation
before the action it must cover. tmux flow control does not provide automatic
backpressure for Erlang subscriber mailboxes. A timeout does not prove that
an already-dispatched command had no effect.

## Package and validation boundaries

Workspace loading and MCP are separate packages that depend on the core.
The core does not depend on their parsers, hosting, or configuration. Package
names and adapter dependencies remain undecided until implementation needs
them.

Implementation must establish parser and quoting behavior, real-tmux
compatibility, completion and cancellation semantics, bounded resource
ownership, and package consumption outside the checkout. Documentation must
use examples that execute those contracts. Current scaffold checks establish
none of these runtime properties; see the
[contribution guide](../.github/CONTRIBUTING.md) for validation scope.
