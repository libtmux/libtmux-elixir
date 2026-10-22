defmodule LibTmux.ControlPublisherIntegrationTest do
  use ExUnit.Case,
    async: false,
    parameterize: [%{publisher: :dies}, %{publisher: :resumes}]

  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Admission, Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag reason:
               "Gates a test-only Control copy before publication with real native ownership"

  setup_all %{publisher: action} do
    module = compile_publisher(action)
    %{publisher_module: module}
  end

  test "an admitted publisher cannot release or follow its retired lease", %{
    publisher: action,
    publisher_module: module
  } do
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
                 waiter_capacity: 2
               )
             )

    endpoint = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    persistent = monitor_actors([parent, root, host, endpoint.manager])
    original = track_epoch(endpoint)
    assert {:ok, probe} = apply(module, :from_descriptor, [Map.from_struct(control)])
    observer = self()
    gate = make_ref()

    {publisher, monitor} =
      spawn_monitor(fn ->
        Process.put(:libtmux_publisher_gate, {observer, gate})

        result =
          try do
            apply(module, :submit, [
              probe,
              Request.set_user_option("@publisher_survival", "original"),
              [timeout: 400]
            ])
          rescue
            error -> {:raised, error.__struct__}
          end

        send(observer, {gate, :returned, result})

        receive do
          {^gate, :finish} -> :ok
        after
          950 -> exit(:publisher_finish_timeout)
        end
      end)

    on_exit(fn -> Process.exit(publisher, :kill) end)
    deadline = Deadline.new(950)

    try do
      assert_receive {^gate, :admitted, ^publisher, operation}, Deadline.remaining(deadline)
      assert {:ok, :reserved} = Admission.state(endpoint.pool, operation.lease)

      if action == :dies do
        Process.exit(publisher, :kill)

        assert_receive {:DOWN, ^monitor, :process, ^publisher, :killed},
                       Deadline.remaining(deadline)

        refute Process.alive?(publisher)
        assert {:ok, :reserved} = Admission.state(endpoint.pool, operation.lease)
      end

      assert {:error, %{kind: :resource_limit, certainty: :no_write}} =
               Control.submit(control, Request.field("pid"), timeout: 100)

      assert {:ok, %{outcome: :skipped, certainty: :no_write} = result} =
               Operation.await(operation, timeout: min(800, Deadline.remaining(deadline)))

      refute Process.alive?(endpoint.router)
      assert :ok = Control.close(control, timeout: min(800, Deadline.remaining(deadline)))
      retire_epoch(original, deadline)
      assert {:ok, %{wire: :retired, result: ^result}} = Operation.status(operation)
      assert Deadline.remaining(deadline) > 0

      assert {:ok, replacement} = Control.reconnect(control, timeout: 800)
      current = replacement.endpoint
      assert current.generation == endpoint.generation + 1
      assert current.epoch != endpoint.epoch
      assert current.instance == endpoint.instance
      replacement_epoch = track_epoch(current)
      deadline = Deadline.new(800)

      assert {:error, %{kind: :resource_limit, certainty: :no_write}} =
               Control.submit(replacement, Request.field("pid"), timeout: 100)

      assert {:ok, ^result} = Operation.result(operation)
      assert :ok = Operation.forget(operation, timeout: Deadline.remaining(deadline))

      assert {:ok, fresh} =
               Control.submit(
                 replacement,
                 Request.set_user_option("@publisher_survival", "replacement"),
                 timeout: Deadline.remaining(deadline)
               )

      assert fresh.lease.slot == operation.lease.slot
      assert fresh.lease.generation > operation.lease.generation

      assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
               Operation.await(fresh, timeout: Deadline.remaining(deadline))

      assert :ok = Operation.forget(fresh, timeout: Deadline.remaining(deadline))

      assert {"replacement\n", 0} =
               OwnedTmux.command(fixture, ["show-options", "-sv", "@publisher_survival"])

      if action == :resumes do
        send(publisher, {gate, :continue})
        assert_receive {^gate, :returned, returned_result}, Deadline.remaining(deadline)
        assert {:ok, returned} = returned_result
        assert returned === operation
        assert {:error, %{kind: :stale_operation}} = Operation.result(returned)
        send(publisher, {gate, :finish})

        assert_receive {:DOWN, ^monitor, :process, ^publisher, :normal},
                       Deadline.remaining(deadline)

        refute Process.alive?(publisher)
      end

      assert {"replacement\n", 0} =
               OwnedTmux.command(fixture, ["show-options", "-sv", "@publisher_survival"])

      assert {:ok, %{phase: :ready, generation: generation}} = Control.status(replacement)
      assert generation == current.generation
      assert Deadline.remaining(deadline) > 0

      cleanup = Deadline.new(950)
      assert :ok = Control.close(replacement, timeout: min(800, Deadline.remaining(cleanup)))
      retire_epoch(replacement_epoch, cleanup)
      assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))
      exited(persistent, cleanup)
      assert Deadline.remaining(cleanup) > 0
      assert OwnedTmux.alive?(fixture)
      assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
    after
      send(publisher, {gate, :continue})
      send(publisher, {gate, :finish})
    end
  end

  defp track_epoch(endpoint) do
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)

    %{
      actors: monitor_actors(Map.values(roles)),
      native: OwnedTmux.watch_processes([helper, guardian.child])
    }
  end

  defp retire_epoch(epoch, deadline) do
    exited(epoch.actors, deadline)
    assert :ok = OwnedTmux.await_exit(epoch.native)
  end

  defp monitor_actors(pids), do: for(pid <- pids, do: {pid, Process.monitor(pid)})

  defp exited(monitors, deadline) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end
  end

  defp compile_publisher(action) do
    module =
      Module.concat(__MODULE__, if(action == :dies, do: DeadPublisher, else: LatePublisher))

    source = File.read!(Path.join(__DIR__, "../lib/libtmux/control.ex"))
    binding = "      %Operation{} = operation = Operation.bind(template, lease)"

    gate = """

          {observer, gate} = Process.get(:libtmux_publisher_gate)
          send(observer, {gate, :admitted, self(), operation})

          receive do
            {^gate, :continue} -> :ok
          after
            950 -> exit(:publisher_gate_timeout)
          end
    """

    source =
      source
      |> replace_once!("defmodule LibTmux.Control do", "defmodule #{inspect(module)} do")
      |> replace_once!("  @derive {Inspect, only: []}\n", "")
      |> replace_once!(binding, binding <> gate)

    Code.compile_string(source, "gated-publisher.ex")
    module
  end

  defp replace_once!(source, old, replacement) do
    assert length(:binary.matches(source, old)) == 1
    String.replace(source, old, replacement)
  end
end
