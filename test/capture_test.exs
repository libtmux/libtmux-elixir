defmodule LibTmux.CaptureTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Command, Error, Format, Selection, Server, Snapshot}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason:
               "Captures linked topology and qualifies bounded reconciliation on an owned tmux server"

  test "capture batches text fields while counting every tmux command" do
    fixture = start_supervised!({OwnedTmux, []})
    server = fixture |> OwnedTmux.info() |> server()
    assert {:ok, snapshot} = Server.snapshot(server, max_commands: 13)
    assert map_size(snapshot.panes) == 1

    assert {:error, %Error{kind: :resource_limit, details: %{reason: :commands}}} =
             Server.snapshot(server, max_commands: 12)

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end

  test "default budgets capture ten windows and 200 panes with owned cleanup" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    script = Path.join(Path.dirname(info.socket), "panes.conf")

    for window <- 0..9 do
      if window > 0 do
        assert {_, 0} = OwnedTmux.command(fixture, ["new-window", "-d", "/bin/cat", "--"])
      end

      target = "@#{window}"
      assert {_, 0} = OwnedTmux.command(fixture, ["resize-window", "-t", target, "-y", "200"])
      split = Command.new("split-window", ["-d", "-t", target, "-l", "1", "/bin/cat", "--"])
      File.write!(script, List.duplicate(Command.render(split) <> "\n", 19))
      assert {_, 0} = OwnedTmux.command(fixture, ["source-file", script])
    end

    assert {pid_text, 0} = OwnedTmux.command(fixture, ["list-panes", "-a", "-F", ~S"#{pane_pid}"])
    pids = pid_text |> String.split() |> Enum.map(&String.to_integer/1)
    assert length(pids) == 200

    try do
      assert {:ok, snapshot} = Server.snapshot(server(info))
      assert map_size(snapshot.sessions) == 1
      assert map_size(snapshot.windows) == 10
      assert map_size(snapshot.panes) == 200
    after
      watch = OwnedTmux.watch_processes([info.server_pid, info.helper_pid | pids])

      assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
               OwnedTmux.close(fixture)

      :ok = OwnedTmux.await_exit(watch)
    end
  end

  test "large fields stay bounded by the complete encoded response" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    name = String.duplicate("x", 32_000)
    script = Path.join(Path.dirname(info.socket), "large-name.conf")
    command = Command.new("rename-window", ["-t", "@0", name])
    File.write!(script, Command.render(command, max_bytes: 131_072) <> "\n")
    assert {_, 0} = OwnedTmux.command(fixture, ["source-file", script])
    server = server(info)
    assert {:ok, snapshot} = Server.snapshot(server)
    assert snapshot.windows["@0"].name == name

    assert {:error, %Error{kind: :resource_limit}} =
             Server.snapshot(server, max_response_bytes: 32_010)

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end

  test "capture preserves physical identity, membership context and hostile text without attachment" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    {_, 0} = OwnedTmux.command(fixture, ["new-session", "-d", "-s", "second", "/bin/cat", "--"])
    {_, 0} = OwnedTmux.command(fixture, ["link-window", "-s", "@0", "-t", "$0:5"])
    {_, 0} = OwnedTmux.command(fixture, ["link-window", "-s", "@0", "-t", "$1:7"])
    name = ~S"api-#{pid} $ ; }" <> " λ"
    {_, 0} = OwnedTmux.command(fixture, ["rename-window", "-t", "@0", Format.literal(name)])
    server = server(info)
    assert {:ok, snapshot} = Server.snapshot(server)
    assert snapshot.windows["@0"].name == name
    assert map_size(snapshot.windows) == 2
    assert map_size(snapshot.window_links) == 4
    assert map_size(snapshot.panes) == 2
    assert snapshot.clients == %{}
    assert Enum.map(Snapshot.related(snapshot, :session, "$0", :panes), & &1.id) == ["%0"]
    assert snapshot.sessions["$0"].attached_count == 0
    assert snapshot.panes["%0"].exit_status == nil
    assert Snapshot.related(snapshot, :session, "$0", :active_window).id == "@0"

    assert ["$0", "$1"] ==
             snapshot
             |> Snapshot.sessions()
             |> Selection.where(active_window: [is: [name: name]])
             |> Enum.map(& &1.id)

    assert snapshot.captured_from <= snapshot.captured_until
    assert {:ok, next} = Server.snapshot(server)
    assert next.id != snapshot.id
    assert next.server_instance == snapshot.server_instance
    assert :ok = Snapshot.require_complete!(next, :client)
    assert {:ok, %{pane_exited: true}} = OwnedTmux.close(fixture)
  end

  test "changing topology exhausts finite read attempts instead of returning a partial graph" do
    fixture = start_supervised!({OwnedTmux, []})

    {_, 0} =
      OwnedTmux.command(fixture, [
        "set-hook",
        "-g",
        "after-list-windows",
        "new-window -d /bin/cat --"
      ])

    assert {:error, %Error{kind: :inconsistent_snapshot, details: %{attempts: 2}}} =
             fixture |> OwnedTmux.info() |> server() |> Server.snapshot(attempts: 2)

    assert {:ok, %{pane_exited: true}} = OwnedTmux.close(fixture)
  end

  test "explicit observer clients retain their identity and raw attachment count" do
    fixture = start_supervised!({OwnedTmux, []})
    assert %{pid: client_pid} = OwnedTmux.attach(fixture)
    assert %{pid: second_client_pid} = OwnedTmux.attach(fixture)
    assert {:ok, snapshot} = fixture |> OwnedTmux.info() |> server() |> Server.snapshot()
    clients = Snapshot.items(snapshot, :client)

    assert Enum.map(clients, & &1.pid) |> Enum.sort() ==
             Enum.sort([client_pid, second_client_pid])

    for client <- clients do
      assert client.control_mode
      assert client.height == nil
      assert client.session_id == "$0"
      assert Snapshot.related(snapshot, :client, client.id, :session) == snapshot.sessions["$0"]
    end

    assert snapshot.sessions["$0"].attached_count == 2
    assert {:ok, %{clients_exited: true, pane_exited: true}} = OwnedTmux.close(fixture)
  end

  test "capture budgets and invalid UTF-8 are explicit errors without truncated success" do
    fixture = start_supervised!({OwnedTmux, []})
    server = fixture |> OwnedTmux.info() |> server()
    assert {:error, %Error{kind: :resource_limit}} = Server.snapshot(server, max_commands: 1)
    assert {:error, %Error{kind: :resource_limit}} = Server.snapshot(server, max_entities: 1)

    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-path-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    path = root <> "/" <> <<255>>
    :ok = :file.make_dir(path)

    try do
      {_, 0} = OwnedTmux.command(fixture, ["new-window", "-d", "-c", path, "/bin/cat", "--"])
      assert {:error, %Error{kind: :invalid_encoding}} = Server.snapshot(server)
    after
      OwnedTmux.close(fixture)
      :ok = :file.del_dir(path)
      File.rmdir!(root)
    end
  end

  test "retryable command error output consumes the original capture byte budget" do
    fixture = start_supervised!({OwnedTmux, []})
    hook = "display-message -p " <> String.duplicate("x", 180) <> "; select-window -t @999999"
    {_, 0} = OwnedTmux.command(fixture, ["set-hook", "-g", "after-list-windows", hook])

    assert {:error, %Error{kind: :resource_limit}} =
             fixture
             |> OwnedTmux.info()
             |> server()
             |> Server.snapshot(attempts: 3, max_bytes: 400, max_response_bytes: 256)

    assert {:ok, %{pane_exited: true}} = OwnedTmux.close(fixture)
  end

  defp server(info) do
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    Server.new(executable: executable, socket: info.socket)
  end
end
