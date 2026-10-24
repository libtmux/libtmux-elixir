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
window = Session.active_window(snapshot, session)
pane = snapshot |> Snapshot.panes() |> Selection.one!(window_id: window.id, active: true)
{:ok, session_ref} = Ref.from_observation(session)
{:ok, window_ref} = Ref.from_observation(window)
{:ok, pane_ref} = Ref.from_observation(pane)

{:ok, created_id} =
  Control.with_connection(
    [server: server, session: {:existing, session.id}, lane: :host_qualified],
    fn control ->
      :ok = Session.rename!(control, session_ref, "work")
      :ok = Window.rename!(control, window_ref, "editor")

      %{id: id, ref: created} =
        Pane.split!(control, pane_ref, command: {:argv, ["/bin/cat"]})

      false = snapshot |> Snapshot.panes() |> Selection.member_id?(id)
      :ok = Pane.send_text!(control, created, "hello")
      :ok = Pane.send_keys!(control, created, ["Enter"])

      for _ <- 1..128 do
        %{outcome: :completed, certainty: :acknowledged, lines: ["v1:" <> ^id]} =
          Control.execute!(control, Request.field("pane_id", created))
      end

      id
    end
  )

IO.puts(JSON.encode!(%{created_pane: created_id, repeated_reads: 128, connection_retired: true}))
