# Contributing

This repository is an unpublished Elixir package scaffold. Current checks
validate package metadata and formatting; there is no tmux implementation
or test suite. [WRITING.md](WRITING.md) governs prose, comments, and commits.

## Setup

Use the versions pinned in [`.tool-versions`](../.tool-versions): Elixir
`1.20.4` built for OTP `29`, with Erlang/OTP `29.1.2`. Install the toolchain
with your version manager before timing checks, then verify it:

```console
$ elixir --version
```

Hex is required only for package archive checks. Install it separately from
the check loops if it is missing:

```console
$ mix local.hex --force
```

The core currently declares no dependencies. Keep third-party runtime
dependencies at zero; development tools may be added when they serve an
actual check. tmux is not needed to validate this scaffold. The proposed
implementation floor is tmux `3.3`, and support must be proved against that
version rather than inferred from a newer local binary.

## Current checks

Check formatting after an edit:

```console
$ time mix format --check-formatted
```

Before handing off a change, validate the Mix project with warnings treated
as errors:

```console
$ time mix compile --warnings-as-errors
```

With Hex already installed, build the local archive:

```console
$ time mix hex.build
```

The compile command currently generates application metadata; there are no
library modules to compile. The archive proves that Hex can package the
declared files, not that a usable tmux API exists. Do not add empty source
or tests merely to make a command appear useful. Add `mix test`, docs, and
installed-consumer gates when the corresponding implementation exists.

## Check budgets

Time the entire command, including startup and setup. Record duration and
scope in the pull request. Tool installation happens before a timed loop.

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Formatting or critical tests for the edited code |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, and generated-file checks |
| Outer | Under 5 minutes | Under 60 seconds | Compilation, packaging, docs, and integration matrices |

The scaffold currently has formatting in the inner loop and compilation
and packaging in the outer loop. No unit suite exists for the mid loop.
Do not run network operations, installs, builds, browsers, sleeps, or broad
corpus scans in the inner or mid loop.

Investigate waits longer than one second; use events and subscriptions for
readiness instead of fixed sleeps. Slow tests need an outer-loop tag and a
one-line reason. Fix redundant setup, polling, and slow paths before adding
tests to an over-budget loop. Benchmarks are separate: each run stays under
10 minutes, and a full sweep stays under one hour.

## Package boundaries

[mix.exs](../mix.exs) owns the core package. The future workspace loader and
MCP server will be separate Mix packages that consume the core. Do not add
adapter dependencies or adapter configuration to the core. The
[design note](../docs/design.md) records the planned behavioral boundaries.

## Adding implementation

Add tests for critical behavior and regressions, not copies of the
implementation. A regression test must fail for the intended reason before
its passing result becomes evidence. Prefer pure ExUnit tests for parsing,
encoding, and selection; exercise protocol and resource ownership against
real tmux as well.

Every tmux fixture uses a unique, owned socket and temporary directory.
Clear inherited `TMUX` and `TMUX_PANE`. Never connect tests to the default
server, and only stop servers or remove files owned by that run. Use
bounded, event-based readiness and verify cleanup on success and failure.

Use ExUnit supervision for BEAM children and explicit teardown for owned OS
processes. A successful teardown call is not proof that a child exited.
Enable asynchronous tests only when sockets, state, and cleanup are isolated.
Distinguish protocol acknowledgement from operation completion in assertions.

Each support claim needs its own required CI cell. The tmux floor must run
against tmux `3.3` itself; `3.3a` is a separate compatibility case. Platform
and transport coverage remain unverified until implementation exercises
them. Missing prerequisites in a required cell fail that cell; report
optional skips explicitly.

## Pull requests

Keep changes on a topic branch in a separate worktree. Preserve unrelated
edits and keep each PR focused on one reviewable change. Follow the commit
format in [WRITING.md](WRITING.md).

Describe the problem, resulting behavior, and relevant validation. Report
passing, failing, skipped, and unverified checks separately. Scope claims to
what the checks actually exercise; scaffold validation cannot establish
runtime compatibility, performance, or release readiness.

## Publication

No release or publishing workflow is configured. Building a local archive
does not publish it. Publication needs separate authorization and, once
implementation exists, an installed-consumer check outside the checkout,
verified package contents and documentation links, and the required runtime
matrix. Future adapters must consume real package versions rather than
repository-relative dependencies in published metadata.
