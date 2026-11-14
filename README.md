<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Elixir">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

<h1>libtmux for Elixir</h1>

<p>
  <a href="https://hex.pm/packages/libtmux">Hex.pm</a> ·
  <a href="https://libtmux.org/en/elixir/latest/reference/">API reference</a> ·
  <a href="https://libtmux.hexdocs.pm/">HexDocs</a> ·
  <a href="https://libtmux.org/en/elixir/">Documentation</a>
</p>

<p>
  <a href="https://github.com/libtmux/libtmux-elixir/actions/workflows/scaffold.yml"><img src="https://github.com/libtmux/libtmux-elixir/actions/workflows/scaffold.yml/badge.svg" alt="Core checks"></a>
  <a href="https://hex.pm/packages/libtmux"><img src="https://img.shields.io/hexpm/v/libtmux?label=libtmux" alt="libtmux"></a>
  <a href="https://libtmux.org/en/elixir/"><img src="https://img.shields.io/badge/docs-libtmux.org-0b7285" alt="libtmux.org"></a>
  <a href="https://github.com/libtmux/libtmux-elixir/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="license"></a>
</p>

</div>

Drive tmux from Elixir: [capture][snapshot] sessions, windows and panes as an
immutable snapshot, [filter][where] it with plain data, then rename, split and
type through domain actions.

**Contents** — [Installation](#installation) ·
[Try the examples](#try-the-examples) ·
[Find things](#find-sessions-windows-and-panes) ·
[Rename](#rename-a-window) ·
[Control](#split-a-pane-and-send-input) ·
[Errors](#errors-and-recovery) ·
[Guides](#guides) · [Support](#support-and-status) ·
[Leaves out](#what-it-leaves-out)

## Installation

Add the package to your Mix dependencies:

```elixir
{:libtmux, "~> 0.1"}
```

Fetch dependencies:

```console
$ mix deps.get
```

It needs:

- Elixir 1.20 or newer, on OTP 29 or newer
- tmux 3.3 or newer
- Linux and a C compiler, which builds a small helper
- no third-party runtime packages and no NIF

The exact floors and tested releases are in
[Packages and support](docs/implementation.md#packages-and-support).

## Try the examples

The snippets below form one [executable program](examples/readme.exs). From
this checkout, run it on a private tmux server:

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/readme.exs
```

- The [runner](docs/owned-server.md) starts the server, passes in the
  executable, socket and session ID, and stops the server afterward.
- Your own tmux sessions are untouched. The runner needs Python 3.9+.
- Starting and stopping the server is the host's job; the library never starts
  one.

No checkout? The [standalone demo](docs/standalone-demo.md) installs the
package from Hex. To read an existing server, use the
[capture-only program](docs/first-task.md).

`LibTmux.Server.new/1` picks the socket in this order:

- `:socket` (a path) or `:socket_name`
- `LIBTMUX_SOCKET_PATH`, then `LIBTMUX_SOCKET`
- neither: tmux's choice, which is the server `TMUX` names inside tmux and
  the default socket outside it

A Server with a chosen socket removes `TMUX`.

## Find sessions, windows and panes

### [`Server.snapshot!/2`][snapshot]: what tmux has now

One call captures every session, window and pane as an immutable graph.
[`Snapshot.sessions/1`][snapshot-sessions],
[`Snapshot.windows/1`][snapshot-windows] and
[`Snapshot.panes/1`][snapshot-panes] pick a type, and
[`Selection.where/2`][where] filters it. None of them calls tmux again.

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

`active_ids` is `["%0"]`: the demo server starts with one pane. Capture again
when you need fresh state.

More: [Captured state](docs/observations.md).

### [`Selection.where/2`][where]: filter by data

Criteria are keywords or maps, and can test related panes.
[`Filter.from_json/3`][filter-json] reads the same criteria from JSON, so a
filter can come from a file or a request. [`Selection.filter/2`][filter] takes
an Elixir function instead.

<!-- example: examples/readme.exs#filter -->

```elixir
alias LibTmux.{Filter, Pane, Selection, Snapshot}

windows =
  snapshot
  |> Snapshot.windows()
  |> Selection.where(panes: [some: [active: true, current_command: "cat"]])
  |> Enum.map(& &1.id)

json = """
{"version":1,"entity":"pane",
 "where":{"active":true,"currentCommand":{"in":["cat","nvim"]}}}
"""

{:ok, filter} = Filter.from_json(Pane, json)

pane_ids =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(filter)
  |> Enum.map(& &1.id)

```

<!-- /example -->

`windows` is `["@0"]` and `pane_ids` is `["%0"]`. One pane must meet both
conditions inside `some`.

More: [Filtering](docs/filtering.md).

## Rename a window

### [`Window.rename!/4`][rename]: change a window's name

Continue with the same [`snapshot`][snapshot-type] and
[`server`][server-type]. [`Selection.one!/2`][one] needs exactly one match,
[`Session.active_window/2`][active-window] reads the captured link, and
[`Ref.from_observation/1`][ref] turns an observation into an action target.

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

It returns `:ok` once tmux acknowledges the command. `session:` names the
session whose link to the window to use. The old snapshot keeps the old name.

More: [One-shot actions](docs/one-shot-actions.md).

## Split a pane and send input

### [`Control.with_connection/2`][scope]: one connection for many commands

It attaches a control client to an existing session, runs your callback, and
closes the client. [`Pane.split!/3`][split] returns the new pane's ID and a
bound reference. [`Pane.send_text!/4`][text] sends literal text and
[`Pane.send_keys!/4`][keys] sends named keys. [`Pane.capture!/3`][capture]
reads a screen through one-shot execution.

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

The program prints:

```text
{"window":"editor","active_panes":["%0"],"created_pane":"%1","connection_retired":true}
```

- `{:argv, ["/bin/cat"]}` runs a program directly; `{:shell, "command"}` goes
  through a shell.
- An acknowledgement does not mean the program has read its input.
- `lane: :host_qualified` says you control this server's hooks and aliases.
  The demo runner does. Read the managed-control guide before using another
  host.

More: [Managed control](docs/managed-control.md).

## Errors and recovery

### [`Action.CompletionError`][completion-error]: what went wrong

Actions return `{:ok, result}` only when the command completes; the bang forms
raise instead. A command that times out may still have taken effect, so
inspect it before you retry.

More: [Recovery](docs/recovery.md), [Mental model](docs/mental-model.md).

## Guides

- [Filtering](docs/filtering.md): predicates, relations and finding one match.
- [One-shot actions](docs/one-shot-actions.md): rename, split, input and
  screen capture.
- [Managed control](docs/managed-control.md): one connection, many commands.
- [Mental model](docs/mental-model.md): snapshots, references and results.
- [API reference](https://libtmux.org/en/elixir/latest/reference/): functions
  and types.

## Support and status

- **Alpha.** Releases are numbered `0.1.N`. Any release may change or remove
  exported functions; the [changelog](CHANGELOG.md) marks each break. Pin an
  exact version to avoid one.
- **Linux.** The helper that owns tmux processes needs Linux.
- **tmux.** 3.3 or newer.

## What it leaves out

- **Server lifecycle.** It never starts a server and has no stop call; send
  `kill-server` through [`Server.run/3`][run].
- **A query planner.** Selections run locally over a snapshot; `Query`,
  `Batch` and `Plan` are planned.
- **Change notifications.** `Observation` and `Tracker` are planned.

## AI policy

Use these packages with AI tools as you like. When contributing, check what you
submit and wait for a maintainer's invitation before preparing a pull request.
See the [AI policy](https://libtmux.org/en/meta/ai-policy/), also kept as
[AI_POLICY.md](https://github.com/libtmux/.github/blob/HEAD/AI_POLICY.md).

## Contributing

See [Contributing](.github/CONTRIBUTING.md) for development setup and checks,
and [Writing](.github/WRITING.md) for documentation conventions.

Related projects: [libtmux for Python](https://github.com/tmux-python/libtmux),
[libtmux ports](https://github.com/libtmux), and [tmux](https://github.com/tmux/tmux).
[Artwork](docs/branding.md). Licensed under the [MIT License](LICENSE).

[snapshot]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-snapshot-bang-2/
[snapshot-type]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot/
[snapshot-sessions]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-sessions-1/
[snapshot-windows]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-windows-1/
[snapshot-panes]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-panes-1/
[run]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-run-3/
[server-type]: https://libtmux.org/en/elixir/latest/reference/libtmux-server/
[where]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-where-2/
[filter]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-filter-2/
[filter-json]: https://libtmux.org/en/elixir/latest/reference/libtmux-filter-from_json-3/
[one]: https://libtmux.org/en/elixir/latest/reference/libtmux-selection-one-bang-2/
[active-window]: https://libtmux.org/en/elixir/latest/reference/libtmux-session-active_window-2/
[ref]: https://libtmux.org/en/elixir/latest/reference/libtmux-ref-from_observation-1/
[rename]: https://libtmux.org/en/elixir/latest/reference/libtmux-window-rename-bang-4/
[scope]: https://libtmux.org/en/elixir/latest/reference/libtmux-control-with_connection-2/
[split]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-split-bang-3/
[text]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-send_text-bang-4/
[keys]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-send_keys-bang-4/
[capture]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-capture-bang-3/
[completion-error]: https://libtmux.org/en/elixir/latest/reference/libtmux-action-completionerror/
