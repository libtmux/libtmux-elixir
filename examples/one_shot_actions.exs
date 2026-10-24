alias LibTmux.{Pane, Ref, Selection, Server, Session, Snapshot, Window}

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
{:ok, session_ref} = Ref.new(:session, session.id, snapshot.server_instance)
{:ok, window_ref} = Ref.new(:window, window.id, snapshot.server_instance)
{:ok, pane_ref} = Ref.new(:pane, pane.id, snapshot.server_instance)

%{outcome: :completed} = Session.rename!(server, session_ref, "work")
%{outcome: :completed} = Window.rename!(server, window_ref, "editor", session: session_ref)

%{outcome: :completed, value: created_id} =
  Pane.split!(server, pane_ref,
    axis: :horizontal,
    size: {:percent, 30},
    session: session_ref,
    command: ["/bin/cat", "--"]
  )

{:ok, fresh} = Server.snapshot(server)
created = fresh |> Snapshot.panes() |> Selection.one!(id: created_id)
{:ok, created_ref} = Ref.new(:pane, created.id, fresh.server_instance)
%{outcome: :completed} = Pane.send_text!(server, created_ref, "hello")
%{outcome: :completed} = Pane.send_keys!(server, created_ref, ["Enter"])
%{outcome: :completed, value: screen} = Pane.capture!(server, created_ref, max_bytes: 4096)

{:ok, %{name: "work"}} = Snapshot.fetch(fresh, :session, session.id)
{:ok, %{name: "editor"}} = Snapshot.fetch(fresh, :window, window.id)
false = Selection.member_id?(Snapshot.panes(snapshot), created_id)
IO.puts(JSON.encode!(%{created_pane: created_id, captured_bytes: byte_size(screen)}))
