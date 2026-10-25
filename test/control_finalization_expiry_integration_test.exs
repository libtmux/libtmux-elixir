defmodule LibTmux.ControlFinalizationExpiryIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag reason: "Waits for the existing cleanup deadline with a real suspended EpochHost"

  test "late finalization cannot restore an epoch after cleanup expires" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})

    parent =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor,
        restart: :temporary
      })

    assert {:ok, root, control} =
             Supervisor.start_child(
               parent,
               Control.child_spec(
                 server: server,
                 session: {:existing, "$0"},
                 lane: :host_qualified,
                 timeout: 800,
                 capacity: 1,
                 metadata_capacity: 4,
                 waiter_capacity: 1
               )
             )

    endpoint = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    original = for pid <- Map.values(roles), do: {pid, Process.monitor(pid)}

    persistent =
      for pid <- [parent, root, host, endpoint.manager], do: {pid, Process.monitor(pid)}

    assert {:ok, operation} =
             Control.submit(
               control,
               Request.set_user_option("@late_finalization", "acknowledged"),
               timeout: 800
             )

    assert {:ok, %{outcome: :completed, certainty: :acknowledged} = result} =
             Operation.await(operation, timeout: 800)

    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
    native = OwnedTmux.watch_processes([helper, guardian.child])
    token = watch_finalization(endpoint.manager, host, endpoint.generation, endpoint.epoch)
    assert :ok = :sys.suspend(host, 500)
    deadline = Deadline.new(950)

    try do
      assert {:error, %{kind: :timeout, phase: :close, certainty: :unknown}} =
               Control.close(control, timeout: 100)

      assert_receive {^token, :pending, cutoff}, Deadline.remaining(deadline)
      assert Process.alive?(roles.epoch_supervisor)
      assert :ok = OwnedTmux.await_exit(native)
      assert_receive {^token, expiry_notice, ^cutoff}, Deadline.remaining(deadline)
      assert expiry_notice == :expired
      exited(original, deadline)

      assert {:ok,
              %{
                phase: :unknown,
                generation: generation,
                terminal: %{reason: :closure_requested, phase: :transport, stderr: ""}
              }} = Control.status(control)

      assert generation == endpoint.generation
      assert {:ok, ^result} = Operation.result(operation)

      assert {:status, ^host, {:module, _module}, [_dictionary, :suspended | _rest]} =
               :sys.get_status(host, Deadline.remaining(deadline))

      assert Deadline.remaining(deadline) > 0
    after
      if Process.alive?(host), do: :sys.resume(host, 500)
    end

    assert_receive {^token, :late_finalization}, Deadline.remaining(deadline)

    assert {:ok, %{phase: :unknown, generation: generation}} = Control.status(control)
    assert generation == endpoint.generation

    assert {:error, %{kind: :cleanup_unknown, phase: :connect, certainty: :unknown}} =
             Control.reconnect(control, timeout: Deadline.remaining(deadline))

    assert {:ok, %{phase: :unknown, generation: generation}} = Control.status(control)
    assert generation == endpoint.generation
    assert {:ok, ^result} = Operation.result(operation)
    assert Deadline.remaining(deadline) > 0

    assert {"", 0} =
             OwnedTmux.command(fixture, ["list-clients", "-F", ~S"#{client_pid}"])

    assert {"acknowledged\n", 0} =
             OwnedTmux.command(fixture, ["show-options", "-sv", "@late_finalization"])

    cleanup = Deadline.new(950)
    assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))
    exited(persistent, cleanup)
    assert Deadline.remaining(cleanup) > 0
    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp exited(monitors, deadline) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end
  end

  defp watch_finalization(manager, host, generation, epoch) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           :pending,
           {:noreply,
            %{
              phase: :closing,
              generation: ^generation,
              epoch: ^epoch,
              native_retired: true,
              host_finalized: false,
              unclean: false,
              closing_at: cutoff,
              pending: %{kind: :finalize, target: ^host}
            }},
           _name
           when is_integer(cutoff) ->
             send(observer, {token, :pending, cutoff})
             {:expiry, cutoff}

           {:expiry, cutoff},
           {:noreply,
            %{
              phase: :unknown,
              generation: ^generation,
              epoch: ^epoch,
              unclean: true,
              closing_at: closing_at,
              pending: %{kind: :finalize, target: ^host}
            }},
           _name ->
             if is_nil(closing_at) and cutoff <= System.monotonic_time(:millisecond) do
               send(observer, {token, :expired, cutoff})
               :late
             else
               send(observer, {token, :premature_unknown, cutoff})
               :done
             end

           :late,
           {:noreply,
            %{
              generation: ^generation,
              epoch: ^epoch,
              host_finalized: true,
              pending: nil
            }},
           _name ->
             send(observer, {token, :late_finalization})
             :done

           previous, _event, _name ->
             previous
         end, :pending},
        500
      )

    token
  end
end
