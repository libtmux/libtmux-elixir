alias LibTmux.{Control, Pane, Ref, Selection, Server, Session, Snapshot, Window}
alias LibTmux.Control.Request

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

{:ok, created_id} =
  Control.with_connection(
    [server: server, session: {:existing, session.id}, lane: :host_qualified],
    fn control ->
      %{outcome: :completed} = Session.rename!(control, session_ref, "work")
      %{outcome: :completed} = Window.rename!(control, window_ref, "editor")

      %{outcome: :completed, value: id} =
        Pane.split!(control, pane_ref, command: ["/bin/cat", "--"])

      %{outcome: :completed} = Pane.send_text!(control, pane_ref, "hello")
      %{outcome: :completed} = Pane.send_keys!(control, pane_ref, ["Enter"])

      for _ <- 1..128 do
        %{outcome: :completed, certainty: :acknowledged} =
          Control.execute!(control, Request.field("pane_id", pane_ref))
      end

      id
    end
  )

IO.puts(JSON.encode!(%{created_pane: created_id, repeated_reads: 128, connection_retired: true}))
