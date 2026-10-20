defmodule LibTmux.ControlManagerIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Server}
  alias LibTmux.Control.{Births, Bootstrap, ConnectionSupervisor, Inbox, Lifetime}
  alias LibTmux.Test.OwnedTmux
  alias LibTmux.Transport.Native.Protocol
  @moduletag :integration
  @moduletag reason:
               "Qualifies Manager bootstrap, retirement and explicit reconnect on owned tmux"

  test "explicit reconnect waits for old actor/native retirement and preserves the server incarnation" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})

    parent =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    payload = Protocol.process(executable, Bootstrap.arguments(server, "$0"), cwd: "/", env: %{})

    {:ok, _root, %{view: view, lifetime: lifetime}} =
      Supervisor.start_child(
        parent,
        ConnectionSupervisor.child_spec(
          deadline: Deadline.new(800),
          payload: payload,
          capacity: 2,
          metadata_capacity: 2
        )
      )

    [{:connection, starting}] = :ets.lookup(view, :connection)
    manager = starting.manager
    first = connect(starting)
    assert first.phase == :ready

    assert {"1\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    old = monitor_actors(first)
    :ok = Lifetime.revoke(lifetime, first.generation)
    second = connect(first)
    assert second.generation == first.generation + 1
    assert second.epoch != first.epoch
    assert second.instance == first.instance
    exited(old)

    assert {"1\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    current = monitor_actors(second)
    :ok = Lifetime.revoke(lifetime, second.generation)
    exited(current)

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert :sys.get_state(manager, 500).phase in [:closing, :closed]
  end

  defp connect(endpoint) do
    {:ok, ticket} =
      Inbox.publish(endpoint.inbox, endpoint.epoch, Deadline.new(800), {:reconnect, nil})

    :ok = Inbox.notify(endpoint.inbox)
    token = ticket.token

    try do
      assert_receive {^token, :ready}, 850
      assert {:ok, {:ok, ready}} = Inbox.result(endpoint.inbox, ticket)
      ready
    after
      Inbox.close(endpoint.inbox, ticket)
    end
  end

  defp monitor_actors(endpoint) do
    {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    Enum.map(roles, fn {_role, pid} -> {pid, Process.monitor(pid)} end)
  end

  defp exited(actors) do
    for {pid, monitor} <- actors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 850
      refute Process.alive?(pid)
    end
  end
end
