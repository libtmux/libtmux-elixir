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

An Elixir library for controlling tmux. The core provides exact target
references, shared deadlines, command encoding, bounded protocol parsing,
Linux one-shot execution, immutable graph capture, Enumerable selections and
portable filters.
The domain client API remains under development.

[Contributing](.github/CONTRIBUTING.md) ·
[First task](docs/first-task.md) ·
[Design](docs/design.md) · [Encoding](docs/encoding.md) ·
[Mental model](docs/mental-model.md) ·
[Observations](docs/observations.md) ·
[Filtering](docs/filtering.md) ·
[Ownership](docs/ownership.md) ·
[Writing](.github/WRITING.md) · [Artwork](docs/branding.md)

## Status and requirements

| Component | Current scope |
| --- | --- |
| Mix application | `:libtmux`, version `0.0.1-alpha.1` |
| Development toolchain | Elixir `1.20.x` (at least `1.20.4`) on Erlang/OTP `29.x` |
| Planned tmux floor | `3.3`; fixture checks precede client compatibility qualification |
| Runtime dependencies | No third-party packages; own native I/O helper |
| Platforms | No runtime support matrix has been qualified |

[`.tool-versions`](.tool-versions) selects the development toolchain ranges
for mise and CI. Linux builds require a C11 compiler for the helper. See
[setup](.github/CONTRIBUTING.md#setup) for installation
and upgrades. tmux is not required for the pure checks. Capture, command
execution and the complete example require an external tmux executable.
The supported client API and compatibility matrix remain under qualification.

## Installation

Add the alpha release to your Mix dependencies:

```elixir
{:libtmux, "== 0.0.1-alpha.1"}
```

Fetch dependencies:

```console
$ mix deps.get
```

## Capture, select and execute

From a source checkout, run the complete public API example from the packed
core on a new isolated tmux server. This requires Linux, a C11 compiler,
Python 3 and tmux 3.3 or newer:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

The example captures one graph, selects its active pane, and reads that exact
pane through one-shot and control commands. It checks the acknowledged
result, retires its connection, and verifies owned server cleanup. The check
uses a temporary socket and empty configuration. See the [complete program
and failure behavior](docs/first-task.md).

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
integration checks cover owned startup/teardown and hostile command/format
bytes through real tmux. They do not qualify the future client API or a
complete compatibility matrix.
See [Contributing](.github/CONTRIBUTING.md) for setup, timing budgets, and
the checks required as implementation arrives.

## Planned package boundaries

The core provides immutable observations and explicit tmux operations,
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
