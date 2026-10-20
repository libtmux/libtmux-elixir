defmodule LibTmux.ControlConnectionSupervisorTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}

  alias LibTmux.Control.{
    Admission,
    Births,
    ConnectionSupervisor,
    Inbox,
    Lifetime,
    Manager,
    Records
  }

  alias LibTmux.Test.NativeDriver
  @moduletag :capture_log

  test "Manager restart preserves the root view and lifetime without opening another helper" do
    {parent, root, descriptor} = connection()
    old = endpoint(descriptor.view)
    assert_receive {:driver_open, guardian, _handle}
    {:ok, %{roles: roles}} = Births.snapshot(old.births)
    assert roles.guardian == guardian
    actors = monitor_actors(roles)
    {:ok, lease} = Admission.claim(old.pool, old.epoch, roles.router, Deadline.new(500), 5)
    restarted = watch_restart(root, old.manager)
    Process.exit(old.manager, :kill)
    assert_receive {:restarted, ^restarted}, 500
    exited(actors)
    current = endpoint(descriptor.view)
    assert current.manager != old.manager
    assert current.phase == :unknown and current.generation == 1
    assert current.lifetime == descriptor.lifetime
    assert :ets.info(descriptor.view, :owner) == root
    assert %{phase: :unknown, generation: 1} = Lifetime.status(descriptor.lifetime)
    assert {:error, %Error{kind: :connection_lost}} = Records.fetch(old.records, lease)

    assert {:error, %Error{kind: :connection_lost}} =
             Inbox.publish(old.inbox, old.epoch, Deadline.new(500), {:reconnect, nil})

    refute_receive {:driver_open, _, _}, 0
    assert [{ConnectionSupervisor, ^root, :supervisor, _}] = Supervisor.which_children(parent)
  end

  test "root restart reuses the factory lifetime and invalidates the old view" do
    {parent, root, descriptor} = connection()
    old = endpoint(descriptor.view)
    assert_receive {:driver_open, guardian, _handle}
    {:ok, %{roles: roles}} = Births.snapshot(old.births)
    assert roles.guardian == guardian
    actors = monitor_actors(roles)
    restarted = watch_restart(parent, root)
    Process.exit(root, :kill)
    assert_receive {:restarted, ^restarted}, 500
    exited(actors)
    assert :ets.info(descriptor.view) == :undefined

    assert [{ConnectionSupervisor, replacement, :supervisor, _}] =
             Supervisor.which_children(parent)

    assert replacement != root

    {Manager, manager, :worker, _} =
      Enum.find(Supervisor.which_children(replacement), &(elem(&1, 0) == Manager))

    assert %{phase: :unknown, generation: 1, lifetime: lifetime} = :sys.get_state(manager, 500)
    assert lifetime == descriptor.lifetime
    assert %{phase: :unknown, generation: 1} = Lifetime.status(lifetime)
    refute_receive {:driver_open, _, _}, 0
  end

  defp connection do
    parent =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    spec =
      ConnectionSupervisor.child_spec(
        deadline: Deadline.new(800),
        payload: <<0>>,
        driver: {NativeDriver, observer: self()},
        capacity: 2,
        metadata_capacity: 2
      )

    assert {:ok, root, descriptor} = Supervisor.start_child(parent, spec)
    {parent, root, descriptor}
  end

  defp endpoint(view) do
    [{:connection, endpoint}] = :ets.lookup(view, :connection)
    endpoint
  end

  defp watch_restart(supervisor, target) do
    caller = self()
    token = make_ref()

    debug = fn
      false, {:in, {:EXIT, ^target, _reason}}, _name ->
        true

      true, {:noreply, _state}, _name ->
        send(caller, {:restarted, token})
        :done

      seen, _event, _name ->
        seen
    end

    :ok = :sys.install(supervisor, {debug, false}, 500)
    token
  end

  defp monitor_actors(roles) do
    Enum.map(roles, fn {_role, pid} -> {pid, Process.monitor(pid)} end)
  end

  defp exited(actors) do
    for {pid, monitor} <- actors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 500
      refute Process.alive?(pid)
    end
  end
end
