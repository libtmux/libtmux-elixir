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

<p>
  <a href="https://hex.pm/packages/libtmux">Hex.pm</a> ·
  <a href="https://libtmux.org/en/elixir/latest/reference/">API reference</a> ·
  <a href="https://libtmux.hexdocs.pm/">HexDocs</a> ·
  <a href="https://libtmux.org/en/elixir/">Documentation</a>
</p>

</div>

Capture and query tmux state, then act on exact session, window and pane
references. Observations are immutable; enumeration never runs a command.
Choose bounded one-shot execution or an explicitly qualified control connection.

[Capture and query](#capture-and-query) ·
[Rename a window](#rename-a-window) ·
[Split and send input](#split-a-pane-and-send-input) ·
[Guides](https://libtmux.org/en/elixir/latest/guides/)

## Status and requirements

The `0.0.1-alpha.2` core includes capture/filtering, domain actions, managed
execution and scoped connections. Workspace, MCP, Tracker and dependency
planners remain planned.

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
{:libtmux, "== 0.0.1-alpha.2"}
```

Fetch dependencies:

```console
$ mix deps.get
```

## Run the examples

The snippets below form one [executable program](examples/readme.exs). From
this checkout, run it on a private tmux server:

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/readme.exs
```

The runner supplies an absolute executable, socket and session ID. It creates
an empty-config server with a `cat` pane, clears inherited tmux environment
variables, and verifies cleanup when the program exits. The setup and teardown
stay in the [runner](docs/owned-server.md); the library calls are shown below.
Python 3.9+ is required for this Linux runner, not for the library.

Already have a server? Use the [capture-only program](docs/first-task.md),
which takes its socket explicitly and leaves the server running.

## Capture and query

[`Server.snapshot!/2`][snapshot] captures an immutable graph.
[`Selection.where/2`][where] accepts predicate data; ordinary `Enum` functions
work on the selection. These queries make no further tmux calls.

<!-- example: examples/readme.exs#capture -->

```elixir
alias LibTmux.{Selection, Server, Snapshot}

[executable, socket, session_id] = System.argv()

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

snapshot = Server.snapshot!(server)

active_ids =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(active: true)
  |> Enum.map(& &1.id)

```

<!-- /example -->

The fixture starts with one pane, so `active_ids` is `["%0"]`. To use an
Elixir function as the predicate, choose [`Selection.filter/2`][filter].
Capture again explicitly when you need fresh observations.

## Rename a window

Continue with the same `snapshot` and `server`.
[`Selection.one!/2`][one] requires exactly one match, and
[`Session.active_window/2`][active-window] reads the captured relationship.
[`Ref.from_observation/1`][ref] carries the observed identity into an action.

<!-- example: examples/readme.exs#rename -->

```elixir
alias LibTmux.{Ref, Selection, Session, Snapshot, Window}

session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Session.active_window(snapshot, session)
{:ok, session_ref} = Ref.from_observation(session)
{:ok, window_ref} = Ref.from_observation(window)

Window.rename!(server, window_ref, "editor", session: session_ref)
```

<!-- /example -->

[`Window.rename!/4`][rename] returns `:ok` when tmux acknowledges completion.
The `session` option chooses this window's session membership. The original
snapshot still contains the name captured before the action.

## Split a pane and send input

Continue with that window and session. [`Control.with_connection/2`][scope]
owns connection startup and cleanup around the callback. Its returned value
is available after connection retirement.

<!-- example: examples/readme.exs#control -->

```elixir
alias LibTmux.{Control, Pane, Ref, Selection, Snapshot}

pane = snapshot |> Snapshot.panes() |> Selection.one!(window_id: window.id, active: true)
{:ok, pane_ref} = Ref.from_observation(pane)

{:ok, created_id} =
  Control.with_connection(
    [server: server, session: {:existing, session.id}, lane: :host_qualified],
    fn control ->
      %{id: id, ref: created} =
        Pane.split!(control, pane_ref, axis: :horizontal, command: {:argv, ["/bin/cat"]})

      Pane.send_text!(control, created, "hello")
      Pane.send_keys!(control, created, ["Enter"])
      id
    end
  )

```

<!-- /example -->

[`Pane.split!/3`][split] returns the new pane's ID and bound reference on this
connection. [`Pane.send_text!/4`][text] sends literal text;
[`Pane.send_keys!/4`][keys] sends named keys. `{:argv, ["/bin/cat"]}` requests
a program directly; `{:shell, "command"}` requests shell interpretation.
Acknowledgement does not mean the program has finished processing its input.

The private runner qualifies this example's `lane: :host_qualified` declaration.
That option does not configure or qualify an arbitrary server. Read the
[managed-control guide](docs/managed-control.md) before using another host.
For one-shot screen reads, use [`Pane.capture!/3`][capture].

The complete program verifies the renamed window and new pane in a fresh
snapshot, then prints their IDs and cleanup status. CI runs these same snippets
from the packed library against the supported tmux versions. It also checks
that the displayed code matches the source. Every snippet declares the aliases
it uses; aliases are lexical shorthand, not inferred imports.

## Errors and recovery

Domain bang functions return completed values or raise with failure evidence.
Lower-level Control and Operation bangs preserve canonical outcomes as values.
Timeouts do not imply no effects or authorize replay. The
[recovery example](docs/recovery.md) handles execution and cleanup failures;
[retained operations](docs/advanced-execution.md) support independent inspection.

Default capture budgets are 5000ms, 512 commands, 1024 contextual rows and
8 MiB total encoded output. Limits fail explicitly. Managed execution reclaims
records after wire retirement. See [one-shot actions](docs/one-shot-actions.md)
and [managed control](docs/managed-control.md) for transport and result contracts.

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

[snapshot]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-snapshot-bang-2/
[where]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-where-2/
[filter]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-filter-2/
[one]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-one-bang-2/
[active-window]: https://libtmux.org/en/elixir/latest/reference/libtmux-session-active_window-2/
[ref]: https://libtmux.org/en/elixir/latest/reference/libtmux-ref-from_observation-1/
[rename]: https://libtmux.org/en/elixir/latest/reference/libtmux-window-rename-bang-4/
[scope]: https://libtmux.org/en/elixir/latest/reference/libtmux-control-with_connection-2/
[split]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-split-bang-3/
[text]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-send_text-bang-4/
[keys]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-send_keys-bang-4/
[capture]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-capture-bang-3/
