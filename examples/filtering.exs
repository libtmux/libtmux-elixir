alias LibTmux.{Selection, Server, Snapshot}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, %{value: %{id: session_id}}} =
    Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

  snapshot = Server.snapshot!(server)

  # docs:begin where
  editors = ["cat", "nvim", "vim"]

  active =
    snapshot
    |> Snapshot.panes()
    |> Selection.where(active: true, current_command: [in: editors])

  Enum.map(active, & &1.id)
  # docs:end where

  ["%0"] = Enum.map(active, & &1.id)

  # docs:begin relation
  with_cat =
    Selection.where(Snapshot.sessions(snapshot), %{
      panes: %{some: %{active: true, current_command: "cat"}}
    })

  # docs:end relation

  [%{id: ^session_id}] = Enum.to_list(with_cat)

  # docs:begin wire
  alias LibTmux.{Filter, Pane}

  criteria = [active: true, current_command: [in: ["nvim", "vim"]]]
  {:ok, filter} = Filter.new(Pane, criteria)
  json = filter |> Filter.to_wire() |> JSON.encode!()
  {:ok, ^filter} = Filter.from_json(Pane, json)
  # docs:end wire

  document = """
  {"version":1,"entity":"pane",
   "where":{"active":true,"currentCommand":{"in":["nvim","vim"]}}}
  """

  true = JSON.decode!(json) == JSON.decode!(document)
  IO.puts(JSON.encode!(%{filtering: "ok"}))
end)
