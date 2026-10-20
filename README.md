# libtmux for Elixir

An Elixir library for controlling tmux, currently under implementation.
The unpublished core provides exact target references and shared deadlines.
A tmux client API and supported release are still in development.

[Contributing](.github/CONTRIBUTING.md) ·
[Design](docs/design.md) · [Writing](.github/WRITING.md)

## Status and requirements

| Component | Current scope |
| --- | --- |
| Mix application | `:libtmux`, version `0.1.0-dev`; unpublished |
| Development toolchain | Elixir `1.20.x` (at least `1.20.4`) on Erlang/OTP `29.x` |
| Planned tmux floor | `3.3`; fixture checks precede client compatibility qualification |
| Runtime dependencies | No third-party dependencies |
| Platforms | No runtime support matrix has been qualified |

[`.tool-versions`](.tool-versions) selects the development toolchain ranges
for mise and CI. See [setup](.github/CONTRIBUTING.md#setup) for installation
and upgrades. tmux is not required for the scaffold checks. A future
implementation will require an external tmux executable and its own
compatibility evidence.

## Check the implementation

From the checkout, with the development toolchain on `PATH`, check formatting:

```console
$ mix format --check-formatted
```

Run the pure unit suite:

```console
$ mix test
```

Compile with warnings treated as errors:

```console
$ mix compile --warnings-as-errors
```

With Hex installed, build a local package archive:

```console
$ mix hex.build
```

Check public core imports from a packed archive outside the checkout:

```console
$ mix run scripts/check_package.exs
```

The unit and packed-core checks validate the current foundations. Real
fixture checks prove owned startup and teardown; they do not qualify the
future client API or a complete compatibility matrix.
See [Contributing](.github/CONTRIBUTING.md) for setup, timing budgets, and
the checks required as implementation arrives.

## Planned package boundaries

The core will expose immutable observations and explicit tmux operations,
using Elixir and OTP without third-party runtime dependencies. Workspace
loading and an MCP server have separate Mix projects under `packages/`.
Their runtime implementations remain planned. MCP also consumes workspace
behavior rather than maintaining a second loader or planner.

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
