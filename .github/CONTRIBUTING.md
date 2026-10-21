# Contributing

This unpublished Elixir package is under implementation. Pure foundation
tests, packed-core import checks and owned real-tmux checks are available.
[WRITING.md](WRITING.md) governs prose, comments, and commits.

## Setup

Use mise with the ranges in [`.tool-versions`](../.tool-versions): Erlang/OTP
`29.x` and Elixir `1.20.x`. The Mix project requires at least Elixir `1.20.4`.
Linux builds also require a C11 compiler and Linux headers for the owned
I/O helper. No NIF or third-party runtime package is required. `CC` may name
one compiler executable. Install prerequisites before timing checks:

```console
$ mise install
```

To install newer releases within those ranges without editing the file:

```console
$ mise upgrade erlang elixir
```

With mise active in your shell, verify that Elixir runs on OTP `29` and was
compiled for OTP `29`:

```console
$ elixir --version
```

Mise selects the newest OTP build for an Elixir prefix; the prefix does not
lock the OTP suffix. If a future `1.20` patch adds a newer OTP build, select
its exact `1.20.x-otp-29` version. asdf requires exact versions and cannot
consume these floating ranges directly.

CI reads both ranges from `.tool-versions` and passes them to `setup-beam`
in loose mode, which selects the Elixir build for the installed OTP major.
The action's direct `version-file` mode requires exact versions.

Hex is required only for package archive checks. Install it separately from
the check loops if it is missing:

```console
$ mix local.hex --force
```

The core has no third-party runtime dependencies. ExDoc is a development-only
dependency; install it before timing documentation checks:

```console
$ mix deps.get
```

tmux is not needed for pure unit or packed-core checks. The
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

Check public function specs and type documentation against the compiled API:

```console
$ time mix run scripts/check_public_contracts.exs
```

Compile the consumer fixtures and check the expected Elixir 1.20 diagnostics:

```console
$ time mix run scripts/check_consumer_types.exs
```

Typespecs document contracts; the compiler infers types from implementation
patterns and guards. These fixtures verify selected valid and invalid uses,
not arbitrary criteria or every value-dependent return type. The codec fixture
records a case inference does not currently reject; runtime validation remains
required. Neither a declaration count nor a silent compiler proves every
contract.

With dependencies already installed, render the public reference and guides:

```console
$ time mix docs --warnings-as-errors
```

Check rendered local files and HTML fragments without network requests:

```console
$ time python3 scripts/check_docs_links.py
```

The link check reports ExDoc's optional host-provided version catalogue
separately. It does not verify external websites or publication.

Set `DOCS_SOURCE_REF` to the reviewed commit, branch or release tag when building
documentation for that revision. ExDoc uses `main` by default. Rendered copies
resolve source-file and artwork-directory links without changing the originals.

With Hex already installed, build the local archive:

```console
$ time mix hex.build
```

Run critical pure tests in the inner loop, or all unit tests in the mid loop:

```console
$ time mix test
```

Check generated field, operator and relation documentation after schema changes:

```console
$ time mix run scripts/generate_schema.exs --check
```

Regenerate it with `mix run scripts/generate_schema.exs` before the check.

The default suite excludes the `integration` tag. Linux integration fixtures
require Python 3.9+ with pidfd support and an explicit tmux executable or tmux
on PATH. Python is a development fixture tool, not a core runtime dependency.
The helper owns a foreground tmux server, observes socket readiness through
inotify and verifies server/pane exit through process handles. It uses no
fixed readiness sleeps and never starts the default server.

Run the real fixture checks in the outer loop with the exact tmux binary
being qualified:

```console
$ LIBTMUX_TMUX=/path/to/tmux mix test --include integration
```

Check packed-core consumption and metadata outside the checkout:

```console
$ time mix run scripts/check_package.exs
```

Real checks round-trip command and format syntax with hostile bytes. The
field encoder protects backslashes and control bytes before tmux prints
them; the decoder handles one free-form field per response. It does not
assume separator bytes cannot occur in values. The pure control
parser enforces byte/event limits, but transport receive bounds and shared
lane safety need separate qualification.

The [ownership guide](../docs/ownership.md) describes the one-shot helper,
resource ceilings and remaining distribution gates.

These gates prove current foundations and fixture ownership. They do not
establish a complete client API, installed adapter graphs or compatibility
for unexercised operations. Do not add empty source or tests to make a
command appear useful. Complete runnable examples and adapter consumer checks
arrive with those components.

## Check budgets

Time the entire command, including startup and setup. Record duration and
scope in the pull request. Tool installation happens before a timed loop.

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Formatting or critical tests for the edited code |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, and generated-file checks |
| Outer | Under 5 minutes | Under 60 seconds | Compilation, packaging, docs, and integration matrices |

Formatting and changed pure tests belong in the inner loop; the complete
unit suite belongs in the mid loop. Compilation, packaging and real tmux
fixtures and documentation rendering belong in the outer loop. Dependency
installation stays outside all check loops.
Do not run network operations, installs, builds, browsers, sleeps, or broad
corpus scans in the inner or mid loop.

Investigate waits longer than one second; use events and subscriptions for
readiness instead of fixed sleeps. Slow tests need an outer-loop tag and a
one-line reason. Fix redundant setup, polling, and slow paths before adding
tests to an over-budget loop. Benchmarks are separate: each run stays under
10 minutes, and a full sweep stays under one hour.

## Package boundaries

[mix.exs](../mix.exs) owns the core package. The workspace loader and
MCP server have separate Mix projects that consume the core. Do not add
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
