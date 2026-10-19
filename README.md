# libtmux for Elixir

An Elixir library for controlling tmux, currently an unpublished scaffold.
This repository contains package metadata and contributor instructions. It
does not yet provide a tmux API, executable examples, or a supported release.

[Contributing](.github/CONTRIBUTING.md) ·
[Design](docs/design.md) · [Writing](.github/WRITING.md)

## Status and requirements

| Component | Current scope |
| --- | --- |
| Mix application | `:libtmux`, version `0.1.0-dev`; unpublished |
| Development toolchain | Elixir `1.20.x` (at least `1.20.4`) on Erlang/OTP `29.x` |
| Planned tmux floor | `3.3`; compatibility tests do not exist yet |
| Runtime dependencies | No third-party dependencies |
| Platforms | No runtime support matrix has been qualified |

[`.tool-versions`](.tool-versions) selects the development toolchain ranges
for mise and CI. See [setup](.github/CONTRIBUTING.md#setup) for installation
and upgrades. tmux is not required for the scaffold checks. A future
implementation will require an external tmux executable and its own
compatibility evidence.

## Check the scaffold

From the checkout, with the development toolchain on `PATH`, check formatting:

```console
$ mix format --check-formatted
```

Validate the Mix project and generate its application metadata:

```console
$ mix compile --warnings-as-errors
```

With Hex installed, build a local package archive:

```console
$ mix hex.build
```

These commands validate the scaffold. They do not exercise a tmux client or
prove package usability. There is no application source or test suite yet.
See [Contributing](.github/CONTRIBUTING.md) for setup, timing budgets, and
the checks required as implementation arrives.

## Planned package boundaries

The core will expose immutable observations and explicit tmux operations,
using Elixir and OTP without third-party runtime dependencies. Workspace
loading and an MCP server are planned as separate packages that depend on
the core. Neither adapter is present in this scaffold.

The [design note](docs/design.md) records these boundaries and the contracts
that implementation must prove. It is not an API reference.

## Contributing and references

Follow the [contribution guide](.github/CONTRIBUTING.md) and
[writing guide](.github/WRITING.md). Agent instructions start in
[AGENTS.md](AGENTS.md).

Related projects: [libtmux for Python](https://github.com/tmux-python/libtmux),
[libtmux ports](https://github.com/libtmux), and
[tmux](https://github.com/tmux/tmux).

Licensed under the [MIT License](LICENSE).
