alias LibTmux.{Selection, Server, Snapshot}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

  {:ok, snapshot} = Server.snapshot(server)

  active_ids =
    snapshot
    |> Snapshot.panes()
    |> Selection.where(active: true)
    |> Enum.map(& &1.id)

  IO.puts(JSON.encode!(%{active_panes: active_ids}))
end)
