defmodule LibTmux.ControlSupervisorStartTest do
  use ExUnit.Case, async: true
  alias LibTmux.Deadline
  alias LibTmux.Control.SupervisorStart

  test "the adapter rejects unsupported runtime or compiled OTP majors" do
    assert :ok = SupervisorStart.compatibility(~c"29", "29")

    for runtime <- [~c"28", ~c"29", ~c"30"],
        compiled <- ["28", "29", "30"],
        {runtime, compiled} != {~c"29", "29"} do
      assert {:error, %{kind: :unsupported_runtime, certainty: :no_write, phase: :connect}} =
               SupervisorStart.compatibility(runtime, compiled)
    end
  end

  defmodule GatedSupervisor do
    use Supervisor

    @impl true
    def init({observer, gate}) do
      send(observer, {:initializing, gate, self()})

      if is_reference(gate) do
        receive do
          {^gate, :continue} -> :ok
        end
      end

      Supervisor.init([], strategy: :one_for_one)
    end
  end

  test "successful startup preserves ordinary Supervisor child ownership" do
    {:ok, root} = SupervisorStart.start_link(GatedSupervisor, {self(), nil}, Deadline.new(500))
    root_monitor = Process.monitor(root)

    try do
      assert_receive {:initializing, nil, ^root}
      spec = Supervisor.child_spec({Agent, fn -> :owned end}, id: :child)
      assert {:ok, child} = Supervisor.start_child(root, spec)
      child_monitor = Process.monitor(child)
      assert [{:child, ^child, :worker, [Agent]}] = Supervisor.which_children(root)
      assert :owned = Agent.get(child, & &1)
      assert :ok = :sys.terminate(root, :normal, 100)
      assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
      assert_receive {:DOWN, ^child_monitor, :process, ^child, :shutdown}
    after
      Process.unlink(root)
      Process.exit(root, :kill)
    end
  end

  test "an expired deadline rejects startup before spawning a Supervisor" do
    deadline = %Deadline{expires_at: System.monotonic_time(:millisecond) - 1}

    assert {:error, :timeout} =
             SupervisorStart.start_link(GatedSupervisor, {self(), nil}, deadline)

    refute_receive {:initializing, _, _}, 0
  end

  test "the original startup deadline kills a gated init without killing or leaking to its caller" do
    observer = self()
    gate = make_ref()

    caller =
      start_supervised!(
        {Task,
         fn ->
           result =
             SupervisorStart.start_link(GatedSupervisor, {observer, gate}, Deadline.new(25))

           send(
             observer,
             {gate, result, Process.info(self(), :monitors), Process.info(self(), :links)}
           )

           receive do
             {^gate, :finish} -> :ok
           end
         end}
      )

    assert_receive {:initializing, ^gate, root}, 100
    monitor = Process.monitor(root)

    try do
      assert_receive {^gate, {:error, :timeout}, {:monitors, []}, {:links, links}}, 100
      refute root in links
      assert Process.alive?(caller)
      assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, 100
      refute_receive {^gate, _unexpected}, 0
    after
      Process.unlink(root)
      Process.exit(root, :kill)
      send(caller, {gate, :finish})
    end
  end
end
