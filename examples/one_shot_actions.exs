alias LibTmux.{Action, Pane, Ref, Selection, Server, Session, Snapshot, Window}

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

{:ok, snapshot} = Server.snapshot(server)
session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Snapshot.related(snapshot, :session, session.id, :active_window)
pane = snapshot |> Snapshot.panes() |> Selection.one!(window_id: window.id, active: true)
{:ok, session_ref} = Ref.from_observation(session)
{:ok, window_ref} = Ref.from_observation(window)
{:ok, pane_ref} = Ref.from_observation(pane)

Session.rename!(server, session_ref, "work") |> Action.value!()
Window.rename!(server, window_ref, "editor", session: session_ref) |> Action.value!()

created_id =
  Pane.split!(server, pane_ref,
    axis: :horizontal,
    size: {:percent, 30},
    session: session_ref,
    command: ["/bin/cat", "--"]
  )
  |> Action.value!()

{:ok, fresh} = Server.snapshot(server)
created = fresh |> Snapshot.panes() |> Selection.one!(id: created_id)
{:ok, created_ref} = Ref.from_observation(created)
Pane.send_text!(server, created_ref, "hello") |> Action.value!()
Pane.send_keys!(server, created_ref, ["Enter"]) |> Action.value!()
screen = Pane.capture!(server, created_ref, max_bytes: 4096) |> Action.value!()

{:ok, %{name: "work"}} = Snapshot.fetch(fresh, :session, session.id)
{:ok, %{name: "editor"}} = Snapshot.fetch(fresh, :window, window.id)
false = Selection.member_id?(Snapshot.panes(snapshot), created_id)
IO.puts(JSON.encode!(%{created_pane: created_id, captured_bytes: byte_size(screen)}))
