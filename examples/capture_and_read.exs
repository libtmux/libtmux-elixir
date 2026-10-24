alias LibTmux.{Codec, Command, Control, Format, Operation, Ref, Selection, Server, Snapshot}
alias LibTmux.Control.Request

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    cwd: "/",
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

{:ok, snapshot} = Server.snapshot(server)
session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Snapshot.related(snapshot, :session, session.id, :active_window)

pane =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(window_id: window.id)
  |> Selection.filter(& &1.active)
  |> Selection.one!()

{:ok, target} = Ref.new(:pane, pane.id, snapshot.server_instance)
command = Command.new("display-message", ["-p", "-t", pane.id, Format.field("pane_id")])
{:ok, %{stdout: stdout, cleanup: :retired}} = Server.run(server, command)
{:ok, one_shot_id} = Codec.decode_field(stdout, :string, encoding: :escaped_v1)
true = one_shot_id == pane.id

{:ok, root, control} =
  Control.start_link(
    server: server,
    session: {:existing, session.id},
    lane: :host_qualified,
    timeout: 800
  )

root_monitor = Process.monitor(root)

control_id =
  try do
    {:ok, operation} = Control.submit(control, Request.field("pane_id", target), timeout: 800)

    {:ok,
     %{
       outcome: :completed,
       certainty: :acknowledged,
       evidence: :command_reply,
       lines: [line]
     }} = Operation.await(operation, timeout: 800)

    {:ok, %{phase: :ready}} = Control.status(control)
    {:ok, %{result: %{outcome: :completed}}} = Operation.status(operation)

    {:ok, id} = Codec.decode_field(line <> "\n", :string, encoding: :escaped_v1)
    true = id == pane.id
    :ok = Control.close(control, timeout: 800)
    {:ok, %{phase: :retired, terminal: %{reason: :closure_requested}}} = Control.status(control)
    {:ok, %{outcome: :completed}} = Operation.result(operation)
    :ok = Operation.forget(operation, timeout: 800)
    id
  after
    try do
      :ok = Control.close(control, timeout: 800)
    after
      :ok = Supervisor.stop(root, :normal, 800)

      receive do
        {:DOWN, ^root_monitor, :process, ^root, :normal} -> :ok
      after
        800 -> raise "connection supervisor did not exit"
      end
    end
  end

IO.puts(
  JSON.encode!(%{
    "session" => session.id,
    "window" => window.id,
    "pane" => pane.id,
    "oneShot" => one_shot_id,
    "control" => control_id,
    "connectionRetired" => true
  })
)
