<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Elixir">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Elixir

</div>

Capture and query tmux state, then act on exact session, window and pane
references. Observations are immutable; enumeration never runs a command.
Choose bounded one-shot execution or an explicitly qualified control connection.

[Capture and filter](docs/first-task.md) ·
[One-shot actions](docs/one-shot-actions.md) ·
[Managed control](docs/managed-control.md) ·
[Owned examples](docs/owned-server.md)

## Status and requirements

The published alpha is `0.0.1-alpha.1`. This development revision adds domain
actions, managed execution and scoped connections; those helpers are not in
that published artifact. Observation/filtering and retained control APIs
already exist. Workspace, MCP, Tracker and dependency planners remain planned.

| Requirement | Scope |
| --- | --- |
| Elixir / OTP | Elixir 1.20.4 or later 1.20 patch, compiled for OTP 29; OTP 29.1.2 or later 29 patch |
| Runtime platform | Linux, with a C11 compiler and headers to build the external helper |
| tmux | Required compatibility cells: 3.3, 3.3a, 3.4 and 3.8; other versions need their own evidence |
| Dependencies | Zero third-party core runtime packages; no NIF |

The development selectors in [`.tool-versions`](.tool-versions) do not extend
support to older OTP patches. Python is needed only for the optional owned
example runner and integration tooling. See [setup](.github/CONTRIBUTING.md#setup).

## Installation

Add the published alpha to your Mix dependencies:

```elixir
{:libtmux, "== 0.0.1-alpha.1"}
```

Fetch dependencies:

```console
$ mix deps.get
```

Start with the short [installed-consumer capture/filter program](docs/first-task.md).
It accepts an absolute executable and the socket of the existing server you
select. It does not create a server or attach a control client.

## Choose a task

| Task | Guide |
| --- | --- |
| Capture and query locally | [First task](docs/first-task.md), [filtering](docs/filtering.md) |
| Split, rename, send input, capture screen bytes | [One-shot actions](docs/one-shot-actions.md) |
| Reuse a connection and reclaim completed work | [Managed control](docs/managed-control.md) |
| Run a private demonstration with verified cleanup | [Owned server](docs/owned-server.md) |
| Inspect retained operations and both transports | [Advanced execution](docs/advanced-execution.md) |

Default capture budgets are 5000ms, 512 commands, 1024 contextual rows and
8 MiB total encoded output. Limits fail explicitly. Managed execution reclaims
records only after wire retirement; retained operations remain available when
needed. Timeouts do not imply no effects or authorize replay. Bang execution
methods raise API errors while preserving canonical failed outcomes as values.
See the relevant task guide before handling failures.

## Concepts and reference

Read the [mental model](docs/mental-model.md) for server, snapshot, reference
and operation lifetimes. [Observations](docs/observations.md) and the generated
[schema](docs/schema.md) describe captured coverage and relationships. Public
modules carry specs, types and linked examples in the API reference.

[Encoding](docs/encoding.md) and [ownership](docs/ownership.md) explain runtime
constraints. [Design](docs/design.md) and [implementation contracts](docs/implementation.md)
distinguish implemented core behavior from planned consumer packages. The
core never depends on workspace or MCP.

## Contributing

Follow [Contributing](.github/CONTRIBUTING.md), [Writing](.github/WRITING.md)
and [AGENTS.md](AGENTS.md). Check a packed artifact and all public examples
outside the checkout:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

That command requires the Linux development prerequisites and tmux. The
contribution guide lists pure checks, the required runtime matrix, rendered
docs and package verification. Local checks do not establish hosted delivery.

Related projects: [libtmux for Python](https://github.com/tmux-python/libtmux),
[libtmux ports](https://github.com/libtmux), and [tmux](https://github.com/tmux/tmux).
[Artwork](docs/branding.md). Licensed under the [MIT License](LICENSE).
