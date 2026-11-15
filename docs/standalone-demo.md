# Run the standalone demo

This self-contained program installs the published package, starts a private
server, adds a pane and a window, and prints `demo: 2 windows, 3 panes`. It
needs no shell step: `Server.with_owned/2` starts the server and stops it.

It needs Linux, Elixir 1.20 on OTP 29, a C compiler and tmux 3.3 or newer on
`PATH`. The first run needs network access to install the package. Save it as
`quickstart.exs`:

<!-- example: examples/quickstart.exs -->

```elixir
Mix.install([{:libtmux, "~> 0.1.2"}])

alias LibTmux.{Pane, Ref, Selection, Server, Session, Snapshot}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"
cat = [command: {:argv, ["/bin/cat"]}]

Server.with_owned([executable: tmux], fn server ->
  Server.new_session!(server, "demo", cat)

  snapshot = Server.snapshot!(server)
  session = snapshot |> Snapshot.sessions() |> Selection.one!()
  pane = snapshot |> Snapshot.panes() |> Selection.one!()
  {:ok, session_ref} = Ref.from_observation(session)
  {:ok, pane_ref} = Ref.from_observation(pane)

  Pane.split!(server, pane_ref, cat)
  Session.new_window!(server, session_ref, "logs", cat)

  snapshot = Server.snapshot!(server)
  windows = snapshot |> Snapshot.windows() |> Selection.size()
  panes = snapshot |> Snapshot.panes() |> Selection.size()
  IO.puts("#{session.name}: #{windows} windows, #{panes} panes")
end)
```

<!-- /example -->

Run it outside a Mix project:

```console
$ elixir quickstart.exs
```

- The server lives in a private directory with no inherited `TMUX`. It stops
  and the directory goes on a normal return and on a raised exception.
  Killing the VM leaves the directory, though the server stops.
- The requirement `~> 0.1.2` names the first release that has
  `Server.with_owned/2`.
- For supervised control and process-exit evidence, see
  [Own a private server](owned-server.md). The demo does not qualify an
  arbitrary server for shared control.

Next: [capture and filter](first-task.md), or the domain helpers in
[one-shot actions](one-shot-actions.md).
