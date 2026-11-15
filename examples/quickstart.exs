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
