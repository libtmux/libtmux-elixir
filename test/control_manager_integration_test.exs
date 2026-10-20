defmodule LibTmux.ControlManagerIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Deadline, Error, Operation, Server}

  alias LibTmux.Control.{
    Admission,
    Births,
    Inbox,
    Lifetime,
    Records,
    Request
  }

  alias LibTmux.Test.OwnedTmux
  @moduletag :integration
  @moduletag reason:
               "Qualifies Manager bootstrap, retirement and explicit reconnect on owned tmux"

  test "direct linked startup returns ready info and preserves a failed attachment reason" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})
    options = [server: server, session: {:existing, "$0"}, lane: :host_qualified, timeout: 800]
    assert {:ok, root, control} = Control.start_link(options)
    assert {:links, links} = Process.info(root, :links)
    assert self() in links
    assert {:ok, %{phase: :ready}} = Control.status(control)
    root_monitor = Process.monitor(root)
    [{:connection, endpoint}] = :ets.lookup(control.view, :connection)
    actors = monitor_actors(endpoint)
    assert :ok = Control.close(control, timeout: 800)
    exited(actors)
    assert :ok = Supervisor.stop(root, :normal, 500)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}, 100

    assert {:error, %Error{kind: :command_error, phase: :connect, certainty: :unknown} = error} =
             Control.start_link(Keyword.put(options, :session, {:existing, "$999999"}))

    assert %{root: failed_root, root_exited: true, cleanup: :unknown} = error.details
    refute Process.alive?(failed_root)

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])
  end

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

    {:ok, root, control} =
      Supervisor.start_child(
        parent,
        Control.child_spec(
          server: server,
          session: {:existing, "$0"},
          lane: :host_qualified,
          timeout: 800,
          capacity: 2,
          metadata_capacity: 4,
          waiter_capacity: 2
        )
      )

    view = control.view
    lifetime = control.lifetime
    [{:connection, first}] = :ets.lookup(view, :connection)
    manager = first.manager
    assert first.phase == :ready
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
    :ok = Control.close(control, timeout: 800)
    assert {:ok, %{phase: :retired}} = Control.status(control)
    {:ok, replacement} = Control.reconnect(control, timeout: 800)
    [{:connection, second}] = :ets.lookup(view, :connection)
    assert {:ok, %{epoch: epoch, phase: :ready}} = Control.status(replacement)
    assert epoch == second.epoch
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

    assert :ok = Control.close(replacement, timeout: 800)
    assert :sys.get_state(manager, 500).phase in [:closing, :closed]
    root_monitor = Process.monitor(root)
    assert :ok = Supervisor.terminate_child(parent, Control)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, 100
    assert {:ok, fresh_root, inert} = Supervisor.restart_child(parent, Control)
    assert fresh_root != root
    assert {:ok, %{phase: :retired}} = Control.status(inert)

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert {:ok, third} = Control.reconnect(inert, timeout: 800)
    assert {:ok, %{phase: :ready, generation: 3}} = Control.status(third)
    assert {:error, %{kind: :connection_lost}} = Control.status(replacement)
    [{:connection, third_endpoint}] = :ets.lookup(third.view, :connection)
    final_actors = monitor_actors(third_endpoint)
    assert :ok = Control.close(third, timeout: 800)
    exited(final_actors)
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
