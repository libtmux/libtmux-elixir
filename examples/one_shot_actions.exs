alias LibTmux.{Pane, Ref, Selection, Server, Session, Snapshot, Window}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, %{value: %{id: session_id}}} =
    Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

  {:ok, snapshot} = Server.snapshot(server)
  session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
  window = Session.active_window(snapshot, session)

  pane =
    snapshot
    |> Snapshot.panes()
    |> Selection.one!(window_id: window.id, active: true)

  {:ok, session_ref} = Ref.from_observation(session)
  {:ok, window_ref} = Ref.from_observation(window)
  {:ok, pane_ref} = Ref.from_observation(pane)

  Session.rename!(server, session_ref, "work")
  Window.rename!(server, window_ref, "editor", session: session_ref)

  %{id: created_id, ref: nil} =
    Pane.split!(server, pane_ref,
      axis: :horizontal,
      size: {:percent, 30},
      session: session_ref,
      command: {:argv, ["/bin/cat"]}
    )

  {:ok, fresh} = Server.snapshot(server)
  created = fresh |> Snapshot.panes() |> Selection.one!(id: created_id)
  {:ok, created_ref} = Ref.from_observation(created)
  Pane.send_text!(server, created_ref, "hello")
  Pane.send_keys!(server, created_ref, ["Enter"])
  screen = Pane.capture!(server, created_ref, max_bytes: 4096)

  {:ok, %{name: "work"}} = Snapshot.fetch(fresh, :session, session.id)
  {:ok, %{name: "editor"}} = Snapshot.fetch(fresh, :window, window.id)
  false = Selection.member_id?(Snapshot.panes(snapshot), created_id)

  IO.puts(
    JSON.encode!(%{
      created_pane: created_id,
      captured_bytes: byte_size(screen)
    })
  )
end)
