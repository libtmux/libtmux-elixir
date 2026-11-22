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

  remaining =
    Server.snapshot!(server)
    |> Snapshot.windows()
    |> Enum.map(& &1.id)

  IO.puts(
    JSON.encode!(%{
      session: session_id,
      created_window: logs_id,
      windows_before_kill: windows,
      remaining_windows: remaining
    })
  )
end)
