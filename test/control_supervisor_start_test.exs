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

      if gate == :ignore, do: :ignore, else: Supervisor.init([], strategy: :one_for_one)
    end
  end

  defmodule FailedChildSupervisor do
    use Supervisor

    @impl true
    def init({observer, token}) do
      children = [
        {Agent,
         fn ->
           send(observer, {token, :child, self()})
           :owned
         end},
        %{id: :rejected, start: {__MODULE__, :reject, [observer, token]}}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    def reject(observer, token) do
      send(observer, {token, :rejecting, self()})

      receive do
        {^token, :reject} -> {:error, :refused}
      after
        500 -> raise "child failure gate was not released"
      end
    end
  end

  test "successful startup preserves ordinary Supervisor child ownership" do
    {:ok, root} = SupervisorStart.start_link(GatedSupervisor, {self(), nil}, Deadline.new(500))
    root_monitor = Process.monitor(root)

    try do
      assert_receive {:initializing, nil, ^root}
      assert :proc_lib.translate_initial_call(root) == {:supervisor, SupervisorStart, 1}
      {:links, links} = Process.info(root, :links)
      assert self() in links
      {:dictionary, dictionary} = Process.info(root, :dictionary)
      assert hd(Keyword.fetch!(dictionary, :"$ancestors")) == self()
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

  test "an ignored callback preserves the return and retires the exact root" do
    assert :ignore =
             SupervisorStart.start_link(GatedSupervisor, {self(), :ignore}, Deadline.new(500))

    assert_receive {:initializing, :ignore, root}
    refute Process.alive?(root)
    refute_receive {:ack, ^root, _}, 0
    refute_receive {:nack, ^root, _}, 0
  end

  @tag capture_log: true
  test "a failed later child retires the root and its already-started sibling" do
    observer = self()

    for trap? <- [false, true] do
      token = make_ref()

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, trap?)

          result =
            SupervisorStart.start_link(
              FailedChildSupervisor,
              {observer, token},
              Deadline.new(500)
            )

          send(observer, {token, :returned, result, Process.info(self(), :messages)})
        end)

      assert_receive {^token, :child, child}, 100
      assert_receive {^token, :rejecting, root}, 100
      root_monitor = Process.monitor(root)
      child_monitor = Process.monitor(child)

      try do
        send(root, {token, :reject})
        reason = {:shutdown, {:failed_to_start_child, :rejected, :refused}}
        assert_receive {:DOWN, ^root_monitor, :process, ^root, ^reason}, 100
        assert_receive {:DOWN, ^child_monitor, :process, ^child, :shutdown}, 100

        if trap? do
          assert_receive {^token, :returned, {:error, ^reason}, {:messages, []}}, 100
          assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 100
        else
          # The linked exit may arrive before proc_lib consumes the NACK.
          receive do
            {^token, :returned, {:error, ^reason}, {:messages, []}} ->
              assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 100

            {:DOWN, ^caller_monitor, :process, ^caller, ^reason} ->
              refute_receive {^token, :returned, _, _}, 0
          after
            100 -> flunk("failed startup neither returned nor propagated its linked exit")
          end
        end
      after
        Process.exit(caller, :kill)
        Process.exit(root, :kill)
        Process.exit(child, :kill)
      end
    end
  end

  @tag capture_log: true
  test "normal and abnormal parent exits retire a started supervisor and its child" do
    observer = self()

    for reason <- [:normal, :killed] do
      {caller, caller_monitor} =
        spawn_monitor(fn ->
          {:ok, root} =
            SupervisorStart.start_link(GatedSupervisor, {observer, nil}, Deadline.new(500))

          send(observer, {:started, self(), root})

          receive do
            :finish -> :ok
          end
        end)

      assert_receive {:started, ^caller, root}, 100
      assert_receive {:initializing, nil, ^root}, 100
      root_monitor = Process.monitor(root)
      {:ok, child} = Supervisor.start_child(root, {Agent, fn -> :owned end})
      child_monitor = Process.monitor(child)

      try do
        if reason == :normal, do: send(caller, :finish), else: Process.exit(caller, :kill)
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, ^reason}, 100
        assert_receive {:DOWN, ^root_monitor, :process, ^root, ^reason}, 100
        assert_receive {:DOWN, ^child_monitor, :process, ^child, :shutdown}, 100
      after
        Process.exit(caller, :kill)
        Process.exit(root, :kill)
        Process.exit(child, :kill)
      end
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
           foreign = {:ack, self(), gate}
           send(self(), foreign)

           result =
             SupervisorStart.start_link(GatedSupervisor, {observer, gate}, Deadline.new(25))

           assert_receive ^foreign, 0

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
