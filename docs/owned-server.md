# Own a private server

`Server.with_owned/2` starts a private tmux server, calls your function with
it, and stops the server afterward. Every example in this repository uses it,
so an example is one self-contained program.

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

From a checkout, with tmux 3.3 or newer on `PATH`:

```console
$ mix run examples/private_server.exs
```

## What `start/1` gives you

- A directory of mode 700 below `:root`, which defaults to
  `System.tmp_dir!/0`. It holds the socket and is `TMUX_TMPDIR` for the server
  and its panes.
- A server that never inherits `TMUX` or `TMUX_PANE`, reads an empty
  configuration (`:config_file` changes it) and stays up with no session. `:env`
  adds variables for the server and its panes.
- A return only once the socket answers, within `:timeout` (5000 ms).
- A returned `Server` for every other call: `new_session/3`, `snapshot!/2`,
  `Control.with_connection/2` and the domain actions.

`start/1` returns `{:error, error}` for an invalid option, a socket path over
the 107 bytes `sun_path` allows, a server that exits before it answers and a
timeout. A failed start leaves no directory.

## Who owns it

- The process that calls `start/1` owns the server. When that process exits,
  the native helper retires the server. If the VM is killed, the helper still
  retires the server, but the directory stays.
- `stop/2` sends `kill-server`, waits until the helper proves the server
  exited, and removes the directory. If the server still answers, or the
  directory cannot be removed, it returns an error and keeps the directory;
  call it again to retry.
- `with_owned/2` stops in an `after` step. A failing stop never replaces an
  exception from your function; when your function succeeds, a failing stop
  raises.
- `stop/2` refuses a `Server` that `new/1` built, with kind `:not_owned`. It
  never kills a server you only borrowed.

## What qualifies the control lane

- The server uses an empty configuration by default, a private socket and no
  other clients.
- The examples install no hooks, override no command aliases, enter no pane
  modes and register no output-producing subscriptions.
- The admitted command names and default configuration run against each
  required tmux release.
- That controlled lifetime is why the examples declare
  `lane: :host_qualified`.

## On another host

- An empty configuration alone is not a continuing guarantee.
- The host must control configuration changes and competing clients for the
  whole epoch: effective hooks, overridden aliases, mode-dependent key
  bindings, subscriptions and client-directed messages.
- Do not set the flag on an arbitrary interactive server because startup
  succeeded. Use [one-shot execution](one-shot-actions.md) if that is the
  transport you want.
- The library never silently removes hooks or changes transports.

## Check the packed examples

To run every example from the packed package, outside the checkout, and prove
each left no directory, socket or process:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

The [ownership guide](ownership.md) covers library-owned clients and native
helpers apart from server-owned jobs.
