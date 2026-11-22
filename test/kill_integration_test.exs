defmodule LibTmux.KillIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Command, Error, Pane, Ref, Server, Session, Snapshot, Window}
  alias LibTmux.Action.CompletionError
  alias LibTmux.Test.{Processes, TmuxPath}

  @moduletag :integration
  @moduletag reason: "Kills sessions, windows, panes and servers on real private tmux servers"

  setup do
    tmux = TmuxPath.executable()

    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-kill-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, server} = Server.start(executable: tmux, root: root)

    on_exit(fn ->
      Server.stop(server)
      File.rm_rf!(root)
    end)

    {:ok, server: server}
  end

  defp cat, do: [command: {:argv, ["/bin/cat"]}]

  defp ref!(snapshot, entity, id) do
    {:ok, observation} = Snapshot.fetch(snapshot, entity, id)
    {:ok, ref} = Ref.from_observation(observation)
    ref
  end

  defp ids(server, entity) do
    snapshot = Server.snapshot!(server)

    case entity do
      :session -> Snapshot.sessions(snapshot)
      :window -> Snapshot.windows(snapshot)
      :pane -> Snapshot.panes(snapshot)
    end
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  test "Session.kill removes one session and leaves the others", %{server: server} do
    %{id: keep} = Server.new_session!(server, "keep", cat())
    %{id: drop} = Server.new_session!(server, "drop", cat())
    ref = ref!(Server.snapshot!(server), :session, drop)

    assert {:ok, %{outcome: :completed, value: :ok, transport: :one_shot}} =
             Session.kill(server, ref)

    assert ids(server, :session) == [keep]
  end

  test "Window.kill removes one window", %{server: server} do
    %{id: session_id} = Server.new_session!(server, "work", cat())
    session = ref!(Server.snapshot!(server), :session, session_id)
    %{id: extra} = Session.new_window!(server, session, "logs", cat())
    window = ref!(Server.snapshot!(server), :window, extra)

    assert :ok = Window.kill!(server, window)
    assert ids(server, :window) == ["@0"]
  end

  test "Window.kill checks the optional session context", %{server: server} do
    %{id: first} = Server.new_session!(server, "first", cat())
    %{id: second} = Server.new_session!(server, "second", cat())
    snapshot = Server.snapshot!(server)
    window = ref!(snapshot, :window, "@0")
    wrong = ref!(snapshot, :session, second)

    assert first == "$0"
    assert {:error, %CompletionError{}} = Window.kill(server, window, session: wrong)
    assert ids(server, :window) == ["@0", "@1"]
  end

  test "Pane.kill removes one pane", %{server: server} do
    Server.new_session!(server, "work", cat())
    snapshot = Server.snapshot!(server)
    pane = ref!(snapshot, :pane, "%0")
    %{id: split} = Pane.split!(server, pane, command: {:argv, ["/bin/cat"]})
    assert ids(server, :pane) == ["%0", split]

    assert :ok = Pane.kill!(server, ref!(Server.snapshot!(server), :pane, split))
    assert ids(server, :pane) == ["%0"]
  end

  test "killing a stale reference fails without touching anything", %{server: server} do
    %{id: id} = Server.new_session!(server, "work", cat())
    ref = ref!(Server.snapshot!(server), :session, id)
    Server.new_session!(server, "other", cat())
    assert :ok = Session.kill!(server, ref)

    assert {:error, %CompletionError{result: %{outcome: :failed}}} = Session.kill(server, ref)
    assert ids(server, :session) == ["$1"]
  end

  test "a Control connection is refused before any I/O", %{server: server} do
    %{id: id} = Server.new_session!(server, "work", cat())
    snapshot = Server.snapshot!(server)
    ref = ref!(snapshot, :session, id)

    LibTmux.Control.with_connection(
      [server: server, session: {:existing, id}, lane: :host_qualified],
      fn control ->
        assert {:error, %Error{kind: :unsupported_transport, certainty: :no_write}} =
                 Session.kill(control, ref)

        assert {:error, %Error{kind: :unsupported_transport}} =
                 Window.kill(control, ref!(snapshot, :window, "@0"))

        assert {:error, %Error{kind: :unsupported_transport}} =
                 Pane.kill(control, ref!(snapshot, :pane, "%0"))
      end
    )

    assert ids(server, :session) == [id]
  end

  test "a wrong entity kind is an invalid target", %{server: server} do
    %{id: id} = Server.new_session!(server, "work", cat())
    pane = ref!(Server.snapshot!(server), :pane, "%0")

    assert {:error, %Error{kind: :invalid_target, certainty: :no_write}} =
             Session.kill(server, pane)

    assert ids(server, :session) == [id]
  end

  test "Server.kill stops the daemon and its panes", %{server: server} do
    Server.new_session!(server, "work", cat())

    {:ok, %{stdout: pid}} =
      Server.run(server, Command.new("display-message", ["-p", ~S"#{pid}"]))

    {:ok, %{stdout: panes}} =
      Server.run(server, Command.new("list-panes", ["-a", "-F", ~S"#{pane_pid}"]))

    processes =
      for pid <- String.split(pid <> panes), do: Processes.identity!(String.to_integer(pid))

    assert {:ok, %{outcome: :completed, value: :ok}} = Server.kill(server)
    assert Processes.await_exit(processes) == :ok
    assert {:error, _} = Server.snapshot(server)
  end

  test "Server.kill reports a server that is not running", %{server: server} do
    assert :ok = Server.kill!(server)

    assert {:error, %CompletionError{result: %{outcome: :failed}}} = Server.kill(server)
    assert {:error, %Error{}} = Server.snapshot(server)
  end
end
