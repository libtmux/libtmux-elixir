{:ok, _} = Application.ensure_all_started(:libtmux)

# docs:begin where
alias LibTmux.{Selection, Server, Snapshot}

[executable, socket, session_id] = System.argv()

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

snapshot = Server.snapshot!(server)

active =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(active: true, current_command: [in: ["cat", "nvim", "vim"]])

Enum.map(active, & &1.id)
# docs:end where

["%0"] = Enum.map(active, & &1.id)

# docs:begin relation
alias LibTmux.{Selection, Snapshot}

with_cat =
  Selection.where(Snapshot.sessions(snapshot), %{
    panes: %{some: %{active: true, current_command: "cat"}}
  })

# docs:end relation

[%{id: ^session_id}] = Enum.to_list(with_cat)

# docs:begin wire
alias LibTmux.{Filter, Pane}

{:ok, filter} = Filter.new(Pane, active: true, current_command: [in: ["nvim", "vim"]])
json = filter |> Filter.to_wire() |> JSON.encode!()
{:ok, ^filter} = Filter.from_json(Pane, json)
# docs:end wire

document =
  ~s({"version":1,"entity":"pane","where":{"active":true,"currentCommand":{"in":["nvim","vim"]}}})

true = JSON.decode!(json) == JSON.decode!(document)
IO.puts(JSON.encode!(%{filtering: "ok"}))
