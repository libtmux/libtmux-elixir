defmodule LibTmux.ControlManagerIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Deadline, Operation, Server}

  alias LibTmux.Control.{
    Admission,
    Births,
    Bootstrap,
    ConnectionSupervisor,
    Inbox,
    Lifetime,
    Records,
    Request
  }

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

    {:ok, _root, %{view: view, lifetime: lifetime} = descriptor} =
      Supervisor.start_child(
        parent,
        ConnectionSupervisor.child_spec(
          deadline: Deadline.new(800),
          payload: payload,
          capacity: 2,
          metadata_capacity: 4,
          waiter_capacity: 2
        )
      )

    [{:connection, starting}] = :ets.lookup(view, :connection)
    manager = starting.manager
    first = connect(starting)
    assert first.phase == :ready
    {:ok, control} = Control.from_descriptor(descriptor)
    literal = ~S"literal,#{safe}"

    {:ok, public} =
      Control.submit(control, Request.set_user_option("@public", literal), timeout: 800)

    assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
             Operation.await(public, timeout: 800)

    assert :ok = Operation.forget(public, timeout: 800)
    assert {actual, 0} = OwnedTmux.command(fixture, ["show-options", "-sv", "@public"])
    assert actual == literal <> "\n"
    {operation, lease, waiting, outcome} = operation(first)
    assert {:ok, ^outcome} = Operation.await(operation, timeout: 800)

    assert {"1\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    old = monitor_actors(first)
    :ok = Control.request_close(control)
    second = connect(first)
    assert second.generation == first.generation + 1
    assert second.epoch != first.epoch
    assert second.instance == first.instance

    assert {:error, %{kind: :stale_connection, certainty: :no_write}} =
             Control.submit(control, Request.field("pid"))

    exited(old)
    assert {:ok, %{life: %{result: ^outcome}}} = Records.fetch(second.records, lease)
    assert {:ok, ^outcome} = Operation.result(operation)
    assert :ok = Operation.stop(operation)
    assert Lifetime.allows_write?(lifetime, second.generation)
    assert :ok = Operation.forget(operation, timeout: 800)
    assert {:error, %{kind: :stale_operation}} = Records.fetch(second.records, lease)
    assert {:ok, {:ok, ^outcome}} = Inbox.result(second.waiter_inbox, waiting)
    assert :ok = Inbox.close(second.waiter_inbox, waiting)

    assert {"1\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    current = monitor_actors(second)
    {stopping, _lease, _unpublished} = admit(second)
    assert :ok = Operation.stop(stopping)
    exited(current)

    assert {:ok, %{outcome: :skipped, certainty: :no_write}} =
             Operation.await(stopping, timeout: 800)

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

  defp operation(endpoint) do
    {operation, lease, request} = admit(endpoint)

    {:ok, ticket} =
      Inbox.publish(endpoint.waiter_inbox, endpoint.epoch, Deadline.new(800), {:await, lease})

    :ok = Inbox.notify(endpoint.waiter_inbox)
    send(endpoint.router, {:submit, endpoint.epoch, lease, request})
    token = ticket.token
    assert_receive {^token, :ready}, 850

    assert {:ok, {:ok, %{outcome: :completed, certainty: :acknowledged} = outcome}} =
             Inbox.result(endpoint.waiter_inbox, ticket)

    {operation, lease, ticket, outcome}
  end

  defp admit(endpoint) do
    request = Request.field("pid")
    {:ok, line} = Request.encode(request, endpoint.instance)

    {:ok, lease} =
      Admission.claim(
        endpoint.pool,
        endpoint.epoch,
        endpoint.router,
        Deadline.new(800),
        byte_size(line)
      )

    {Operation.new(endpoint, lease), lease, request}
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
