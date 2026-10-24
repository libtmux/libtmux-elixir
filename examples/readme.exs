{:ok, _} = Application.ensure_all_started(:libtmux)

# docs:begin capture
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

# docs:end capture

# docs:begin rename
alias LibTmux.{Ref, Selection, Session, Snapshot, Window}

session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Session.active_window(snapshot, session)
{:ok, session_ref} = Ref.from_observation(session)
{:ok, window_ref} = Ref.from_observation(window)

Window.rename!(server, window_ref, "editor", session: session_ref)
# docs:end rename

# docs:begin control
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

# docs:end control

fresh = Server.snapshot!(server)
{:ok, %{name: "editor"}} = Snapshot.fetch(fresh, :window, window.id)
{:ok, _created} = Snapshot.fetch(fresh, :pane, created_id)
false = Snapshot.panes(snapshot) |> Selection.member_id?(created_id)

IO.puts(
  JSON.encode!(%{
    active_panes: active_ids,
    window: "editor",
    created_pane: created_id,
    connection_retired: true
  })
)
