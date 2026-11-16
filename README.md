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
[Start a server](#start-a-private-server) ·
[Choose a server](#choose-the-server) ·
[Daemon features](#check-the-daemons-tmux-features) ·
[Find things](#find-sessions-windows-and-panes) ·
[Rename](#rename-a-window) ·
[Control](#split-a-pane-send-input-and-read-the-screen) ·
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

The snippets below form one [executable program](examples/readme.exs). It
starts a private tmux server and stops it afterward. From this checkout, with
tmux on `PATH`:

```console
$ mix run examples/readme.exs
```

- Your own tmux sessions are untouched: the server has its own directory and
  never sees `TMUX`.
- Every example under `examples/` does the same, with no shell step.

No checkout? The [standalone demo](docs/standalone-demo.md) installs the
package from Hex.

## Start a private server

### [`Server.with_owned/2`][with-owned]: a server for one function

It starts a tmux server in a private directory, calls your function with the
[`Server`][server-type], and stops the server afterward, even when the function
raises. [`Server.new_session!/3`][new-session] and
[`Session.new_window!/4`][new-window] create what you work on, and
[`Window.kill!/3`][kill-window] removes it.

<!-- example: examples/private_server.exs -->

```elixir
alias LibTmux.{Ref, Selection, Server, Session, Snapshot, Window}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  cat = [command: {:argv, ["/bin/cat"]}]
  %{id: session_id} = Server.new_session!(server, "work", cat)

  snapshot = Server.snapshot!(server)
  session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
  {:ok, session_ref} = Ref.from_observation(session)

  %{id: logs_id} = Session.new_window!(server, session_ref, "logs", cat)

  snapshot = Server.snapshot!(server)
  logs = snapshot |> Snapshot.windows() |> Selection.one!(id: logs_id)
  {:ok, logs_ref} = Ref.from_observation(logs)
  windows = snapshot |> Snapshot.windows() |> Selection.size()

  :ok = Window.kill!(server, logs_ref)

  remaining = Server.snapshot!(server) |> Snapshot.windows() |> Enum.map(& &1.id)

  IO.puts(
    JSON.encode!(%{
      session: session_id,
      created_window: logs_id,
      windows_before_kill: windows,
      remaining_windows: remaining
    })
  )
end)
```

<!-- /example -->

It prints:

```text
{"session":"$0","created_window":"@1","windows_before_kill":2,"remaining_windows":["@0"]}
```

- [`Server.start/1`][start] and [`Server.stop/2`][stop] are the same call in
  two parts. The process that starts a server owns it, and the server stops
  when that process exits.
- `kill` also exists for [`Session`][kill-session], [`Pane`][kill-pane] and
  [`Server`][kill-server]. A control connection refuses it.

More: [Own a private server](docs/owned-server.md).

## Choose the server

### [`Server.new/1`][server-new]: describe a server that already runs

It builds a descriptor with no I/O. Pass `:socket` for a path or
`:socket_name` for a name; with neither, it reads `LIBTMUX_SOCKET_PATH`, then
`LIBTMUX_SOCKET`, and otherwise leaves the choice to tmux.

<!-- example: examples/choose_server.exs -->

```elixir
alias LibTmux.Server

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

by_path = Server.new(executable: tmux, socket: "/run/user/1000/work.sock")
by_name = Server.new(executable: tmux, socket_name: "work")
from_variable = Server.new(executable: tmux, env: %{"LIBTMUX_SOCKET" => "work"})
from_path_variable = Server.new(executable: tmux, env: %{"LIBTMUX_SOCKET_PATH" => "/tmp/w.sock"})
default = Server.new(executable: tmux, env: %{})

%Server{socket: "/run/user/1000/work.sock", socket_name: nil} = by_path
%Server{socket: nil, socket_name: "work"} = by_name
%Server{socket: nil, socket_name: "work"} = from_variable
%Server{socket: "/tmp/w.sock", socket_name: nil} = from_path_variable
%Server{socket: nil, socket_name: nil} = default

IO.puts(
  JSON.encode!(%{
    by_path: by_path.socket,
    by_name: by_name.socket_name,
    from_variable: from_variable.socket_name,
    from_path_variable: from_path_variable.socket,
    default: "tmux chooses"
  })
)
```

<!-- /example -->

- With neither option nor variable, tmux uses the server `TMUX` names inside
  tmux and its default socket outside it.
- A Server with a chosen socket removes `TMUX` from the environment it gives
  tmux.

More: [Capture an existing server](docs/first-task.md).

## Check the daemon's tmux features

### [`Server.capabilities/2`][server-capabilities]: decide from the daemon's release

[`Capabilities.require/2`][capabilities-require] returns a supported native
primitive or a refusal before dispatch. [`Control.capabilities/2`][control-capabilities]
reads through an established control connection.

Run the [owned program](examples/capabilities.exs) to check event-wait support;
it prints `"available"` on tmux 3.8 and `"refused"` on tmux 3.3.

More: [Check daemon features](docs/capabilities.md).

## Find sessions, windows and panes

### [`Server.snapshot!/2`][snapshot]: what tmux has now

The snippets from here on run inside the function that
[`Server.with_owned/2`](#start-a-private-server) calls, so `server` is its
private server. One call captures every session, window and pane as an immutable graph.
[`Snapshot.sessions/1`][snapshot-sessions],
[`Snapshot.windows/1`][snapshot-windows] and
[`Snapshot.panes/1`][snapshot-panes] pick a type, and
[`Selection.where/2`][where] filters it. None of them calls tmux again.

<!-- example: examples/readme.exs#capture -->

```elixir
alias LibTmux.{Selection, Snapshot}

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

## Split a pane, send input and read the screen

### [`Control.with_connection/2`][scope]: one connection for many commands

It attaches a control client to an existing session, runs your callback, and
closes the client. [`Pane.split!/3`][split] returns the new pane's ID and a
bound reference. [`Pane.send_text!/4`][text] sends literal text and
[`Pane.send_keys!/4`][keys] sends named keys. After the scope closes,
[`Pane.capture!/3`][capture] reads the new pane's screen through the `server`.

<!-- example: examples/readme.exs#control -->

```elixir
alias LibTmux.{Control, Pane, Ref, Selection, Snapshot}

pane = snapshot |> Snapshot.panes() |> Selection.one!(window_id: window.id, active: true)
{:ok, pane_ref} = Ref.from_observation(pane)

{:ok, {created_id, created}} =
  Control.with_connection(
    [server: server, session: {:existing, session.id}, lane: :host_qualified],
    fn control ->
      %{id: id, ref: created} =
        Pane.split!(control, pane_ref, axis: :horizontal, command: {:argv, ["/bin/cat"]})

      Pane.send_text!(control, created, "hello")
      Pane.send_keys!(control, created, ["Enter"])
      {id, created}
    end
  )

screen = Pane.capture!(server, created, max_bytes: 4096)
```

<!-- /example -->

The program prints:

```text
{"window":"editor","active_panes":["%0"],"created_pane":"%1","connection_retired":true}
```

- `{:argv, ["/bin/cat"]}` runs a program directly; `{:shell, "command"}` goes
  through a shell.
- An acknowledgement does not mean the program has read its input, so
  `screen` may not show `hello` yet.
- `Pane.capture!/3` runs one command through the `server`; a control
  connection refuses it.
- `lane: :host_qualified` says you control this server's hooks and aliases.
  A server from `Server.start/1` does. Read the managed-control guide before
  using another host.

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
- [Daemon features](docs/capabilities.md): release decisions and observation boundaries.
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

[with-owned]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-with_owned-2/
[start]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-start-1/
[stop]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-stop-2/
[kill-server]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-kill-2/
[kill-session]: https://libtmux.org/en/elixir/latest/reference/libtmux-session-kill-3/
[kill-window]: https://libtmux.org/en/elixir/latest/reference/libtmux-window-kill-bang-3/
[kill-pane]: https://libtmux.org/en/elixir/latest/reference/libtmux-pane-kill-3/
[new-session]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-new_session-bang-3/
[new-window]: https://libtmux.org/en/elixir/latest/reference/libtmux-session-new_window-bang-4/
[snapshot]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-snapshot-bang-2/
[snapshot-type]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot/
[snapshot-sessions]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-sessions-1/
[snapshot-windows]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-windows-1/
[snapshot-panes]: https://libtmux.org/en/elixir/latest/reference/libtmux-snapshot-panes-1/
[server-type]: https://libtmux.org/en/elixir/latest/reference/libtmux-server/
[server-new]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-new-1/
[server-capabilities]: https://libtmux.org/en/elixir/latest/reference/libtmux-server-capabilities-2/
[control-capabilities]: https://libtmux.org/en/elixir/latest/reference/libtmux-control-capabilities-2/
[capabilities-require]: https://libtmux.org/en/elixir/latest/reference/libtmux-capabilities-require-2/
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
