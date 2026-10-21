defmodule LibTmux.ControlPreReadyIntegrationTest do
  use ExUnit.Case,
    async: false,
    parameterize: [
      %{victim: :router},
      %{victim: :guardian},
      %{victim: :manager},
      %{victim: :root}
    ]

  alias LibTmux.{Control, Deadline, Error, Server}
  alias LibTmux.Control.{Births, Lifetime, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag reason: "Holds a real native started frame before Guardian initialization completes"

  defmodule Driver do
    @behaviour LibTmux.Transport.Native.Driver
    alias LibTmux.{Deadline, Transport.Native.Driver}

    @impl true
    def open(options) do
      :atomics.add_get(options[:counter], 1, 1)
      Process.put(__MODULE__, {options, Deadline.new(500)})
      Driver.open([])
    end

    @impl true
    def command(port, <<?O, _::binary>> = frame) do
      {options, deadline} = Process.get(__MODULE__)
      true = Driver.command(port, frame)
      {:os_pid, helper} = Port.info(port, :os_pid)
      observer = options[:observer]
      token = options[:token]

      receive do
        {^port, {:data, <<?S, child::32>>}} = started ->
          :atomics.put(options[:counter], 2, 1)

          send(
            observer,
            {token, :pre_ready, self(), port, helper, child, Process.get(:"$ancestors")}
          )

          receive do
            {^token, :release} -> :ok
          after
            Deadline.remaining(deadline) ->
              :atomics.put(options[:counter], 2, 3)
              exit(:preready_gate_expired)
          end

          :atomics.put(options[:counter], 2, 2)
          send(self(), started)
          true
      after
        Deadline.remaining(deadline) -> raise "native helper did not identify its child"
      end
    end

    def command(port, frame), do: Driver.command(port, frame)

    @impl true
    defdelegate close(port), to: Driver
  end

  test "pre-ready actor loss cannot publish readiness or reopen its factory", %{victim: victim} do
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

    owned = :ets.new(:preready_owned, [:set, :private])
    track(owned, [parent])
    token = make_ref()
    counter = :atomics.new(3, signed: false)

    spec =
      Control.child_spec(
        server: server,
        session: {:existing, "$0"},
        lane: :host_qualified,
        timeout: 800,
        capacity: 1,
        metadata_capacity: 4,
        waiter_capacity: 1
      )

    %{start: {module, function, [prepared]}} = spec
    lifetime = prepared.options[:lifetime]
    driver = {Driver, [observer: self(), token: token, counter: counter]}
    prepared = %{prepared | options: Keyword.put(prepared.options, :driver, driver)}
    spec = %{spec | start: {module, function, [prepared]}}
    startup = Deadline.new(800)
    request = :gen_server.send_request(parent, {:start_child, spec})

    try do
      assert_receive {^token, :pre_ready, guardian, port, helper, child, ancestors},
                     Deadline.remaining(startup)

      assert [epoch_supervisor, host, root, ^parent | _] = ancestors
      track(owned, [guardian, epoch_supervisor, host, root])
      native = OwnedTmux.watch_processes([helper, child])
      :ets.insert(owned, {:native, native})

      try do
        assert {:connected, ^guardian} = Port.info(port, :connected)
        assert {:os_pid, ^helper} = Port.info(port, :os_pid)
        children = children(root, startup)
        {_, manager, _, _} = Enum.find(children, &(elem(&1, 0) == LibTmux.Control.Manager))
        {_, ^host, _, _} = Enum.find(children, &(elem(&1, 0) == LibTmux.Control.EpochHost))
        track(owned, [manager])
        state = :sys.get_state(manager, Deadline.remaining(startup))
        assert state.phase == :starting and state.pending.kind == :guardian
        assert state.deadline === state.births.deadline
        assert {:ok, %{roles: roles}} = Births.snapshot(state.births)
        assert roles.guardian == guardian and roles.epoch_supervisor == epoch_supervisor
        assert Enum.all?(Map.values(roles), &is_pid/1)
        track(owned, Map.values(roles))
        actors = Map.merge(roles, %{root: root, host: host, manager: manager})
        monitors = Map.new(actors, fn {role, pid} -> {role, {pid, Process.monitor(pid)}} end)
        assert Lifetime.status(lifetime) == %{generation: 1, phase: :starting}
        assert :timeout = :gen_server.wait_response(request, 0)
        assert :atomics.get(counter, 1) == 1 and :atomics.get(counter, 2) == 1

        IO.puts(
          JSON.encode!(%{
            preready_native: %{
              victim: victim,
              helper: helper,
              client: child,
              helper_sha256:
                LibTmux.Transport.Native.executable()
                |> File.read!()
                |> then(&:crypto.hash(:sha256, &1))
                |> Base.encode16(case: :lower)
            }
          })
        )

        retirement = Deadline.new(950)
        {pid, monitor} = monitors[victim]
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, Deadline.remaining(retirement)
        refute Process.alive?(pid)
        if victim != :guardian, do: send(guardian, {token, :release})

        assert {:reply, {:error, {%Error{certainty: :unknown}, _child_spec}}} =
                 :gen_server.receive_response(request, Deadline.remaining(startup))

        for {role, {actor, reference}} <- monitors, role != victim do
          assert_receive {:DOWN, ^reference, :process, ^actor, _reason},
                         Deadline.remaining(retirement)

          refute Process.alive?(actor)
        end

        assert :atomics.get(counter, 2) in [1, 2]
        assert :ok = OwnedTmux.await_exit(native)
        :atomics.put(counter, 3, 1)
        assert Deadline.remaining(retirement) > 0
        assert %{generation: 1, phase: phase} = Lifetime.status(lifetime)
        assert phase in if(victim == :router, do: [:retired, :unknown], else: [:unknown])
        assert {"", 0} = OwnedTmux.command(fixture, ["list-clients", "-F", ~S"#{client_pid}"])

        restart = Deadline.new(800)
        retry = :gen_server.send_request(parent, {:start_child, spec})

        assert {:reply, {:ok, replacement, inert}} =
                 :gen_server.receive_response(retry, Deadline.remaining(restart))

        track(owned, [replacement])
        replacement_children = children(replacement, restart)
        track(owned, for({_, actor, _, _} <- replacement_children, do: actor))

        {_, next_manager, _, _} =
          Enum.find(replacement_children, &(elem(&1, 0) == LibTmux.Control.Manager))

        {_, next_host, _, _} =
          Enum.find(replacement_children, &(elem(&1, 0) == LibTmux.Control.EpochHost))

        inert_state = :sys.get_state(next_manager, Deadline.remaining(restart))
        assert is_nil(inert_state.births) and is_nil(inert_state.pending)
        assert Enum.all?(inert_state.actors, fn {_role, actor} -> is_nil(actor) end)
        assert children(next_host, restart) == []
        assert Lifetime.status(lifetime) == %{generation: 1, phase: phase}
        assert :atomics.get(counter, 1) == 1

        assert {:error, %Error{certainty: :no_write}} =
                 Control.submit(inert, Request.field("pid"), timeout: Deadline.remaining(restart))

        assert {:ok, %{phase: ^phase}} = Control.status(inert)
        assert Deadline.remaining(restart) > 0
        IO.puts(JSON.encode!(%{preready_retirement: %{victim: victim, phase: phase, opens: 1}}))
      after
        send(guardian, {token, :release})
      end
    after
      :gen_server.receive_response(request, 0)
      cleanup_deadline = cleanup(owned)

      if :atomics.get(counter, 3) == 0 do
        case :ets.lookup(owned, :native) do
          [{:native, native}] -> assert :ok = OwnedTmux.await_exit(native)
          [] -> :ok
        end
      end

      assert Deadline.remaining(cleanup_deadline) > 0
      :ets.delete(owned)
    end

    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp track(table, pids) do
    for pid <- pids, is_pid(pid), do: :ets.insert(table, {pid})
  end

  defp cleanup(table) do
    deadline = Deadline.new(950)
    actors = for {pid} <- :ets.tab2list(table), do: {pid, Process.monitor(pid)}
    for {pid, _monitor} <- actors, do: Process.exit(pid, :kill)

    for {pid, monitor} <- actors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end

    deadline
  end

  defp children(supervisor, deadline),
    do: :gen_server.call(supervisor, :which_children, Deadline.remaining(deadline))
end
