defmodule LibTmux.ControlReceiveIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Codec, Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason:
               "Disconnects an owned real control client while its multi-chunk reply is queued"

  @tag :queued_reply
  test "native exit preserves a queued large reply and its registered waiter" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})
    value = String.duplicate("\n", 6000)
    assert {"", 0} = OwnedTmux.command(fixture, ["set-option", "-s", "@receive_tail", value])

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
                 timeout: 800
               )
             )

    endpoint = control.endpoint
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    [{:host, host}] = :ets.lookup(control.view, :host)
    actors = [parent, root, host, endpoint.manager | Map.values(roles)]
    monitors = for pid <- actors, do: {pid, Process.monitor(pid)}
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
    watcher = watch_native(helper, guardian.child)
    gate = hold_first_chunk(roles.router, endpoint.epoch, roles.guardian)
    watch_queued_tail(roles.guardian, gate)
    deadline = Deadline.new(800)
    observer = self()

    outcome =
      try do
        assert {:ok, operation} =
                 Control.submit(control, Request.field("@receive_tail"),
                   timeout: Deadline.remaining(deadline)
                 )

        assert_receive {^gate, :held}, Deadline.remaining(deadline)
        waiter_marker = make_ref()

        {awaiter, awaiter_monitor} =
          spawn_monitor(fn ->
            receive do
              :await ->
                result = Operation.await(operation, timeout: Deadline.remaining(deadline))
                send(observer, {waiter_marker, result})
            end
          end)

        on_exit(fn -> Process.exit(awaiter, :kill) end)
        watch_waiter(endpoint.manager, awaiter, waiter_marker)
        send(awaiter, :await)
        assert_receive {^waiter_marker, :registered}, Deadline.remaining(deadline)
        assert_receive {^gate, :tail_queued}, Deadline.remaining(deadline)
        assert :pending = Operation.result(operation)
        IO.puts(JSON.encode!(%{stage: :queued_reply, waiter_registered: true}))
        watch_drain_exit(roles.guardian, gate)
        assert Port.command(watcher, "terminate\n")
        assert %{"kind" => "exited", "milliseconds" => native_ms} = exit = receive_json(watcher)
        IO.puts(JSON.encode!(exit))
        assert native_ms < 750
        assert_receive {^watcher, {:exit_status, 0}}, Deadline.remaining(deadline)
        assert {:ok, %{phase: :ready}} = Control.status(control)
        assert_receive {^gate, :drain_exited}, Deadline.remaining(deadline)

        current = :sys.get_state(roles.guardian, 500)
        assert %{phase: :ready, drain: drain, stdout_chunks: chunks} = current
        assert chunks >= 2
        assert drain.exit_status == 0
        assert not is_nil(current.terminal)
        refute_receive {^waiter_marker, _outcome}, 0
        send(roles.router, {gate, :continue})

        assert_receive {^waiter_marker, {:ok, %{outcome: :completed, lines: [encoded]}}},
                       Deadline.remaining(deadline)

        assert_receive {:DOWN, ^awaiter_monitor, :process, ^awaiter, :normal},
                       Deadline.remaining(deadline)

        assert {:ok, ^value} = Codec.decode_field(encoded <> "\n", :bytes, encoding: :escaped_v1)
        assert {:ok, %{outcome: :completed}} = Operation.result(operation)
        cleanup = Deadline.new(950)
        assert :ok = Control.close(control, timeout: min(800, Deadline.remaining(cleanup)))
        assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))

        for {pid, monitor} <- monitors do
          assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(cleanup)
          refute Process.alive?(pid)
        end

        assert Deadline.remaining(cleanup) > 0
        assert OwnedTmux.alive?(fixture)
        :ok
      catch
        kind, reason -> {:failed, kind, reason, __STACKTRACE__}
      end

    cleanup =
      try do
        send(roles.router, {gate, :continue})
        if Port.info(watcher), do: Port.close(watcher)

        if Process.alive?(parent) do
          deadline = Deadline.new(950)
          :ok = :sys.terminate(parent, :normal, Deadline.remaining(deadline))

          for {pid, monitor} <- monitors do
            assert_receive {:DOWN, ^monitor, :process, ^pid, _reason},
                           Deadline.remaining(deadline)

            refute Process.alive?(pid)
          end

          assert OwnedTmux.alive?(fixture)
        end

        assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
        :ok
      catch
        kind, reason -> {:failed, kind, reason, __STACKTRACE__}
      end

    case {outcome, cleanup} do
      {{:failed, kind, reason, stack}, other} ->
        if other != :ok, do: IO.inspect(other, label: "additional cleanup failure", limit: 8)
        :erlang.raise(kind, reason, stack)

      {:ok, {:failed, kind, reason, stack}} ->
        :erlang.raise(kind, reason, stack)

      {:ok, :ok} ->
        :ok
    end
  end

  for mode <- [:expiry, :explicit_close, :router_owner_loss] do
    @tag drain_abort: mode
    test "#{mode} during queued EOF preserves an established result", %{drain_abort: mode} do
      fixture = start_supervised!({OwnedTmux, []})
      %{socket: socket} = OwnedTmux.info(fixture)
      executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
      server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})
      value = String.duplicate("\n", 6000)
      assert {"", 0} = OwnedTmux.command(fixture, ["set-option", "-s", "@receive_tail", value])

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
                   timeout: 800
                 )
               )

      endpoint = control.endpoint
      parent_monitor = Process.monitor(parent)
      root_monitor = Process.monitor(root)
      assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
      assert {:ok, established} = Control.submit(control, Request.field("pid"), timeout: 800)
      assert {:ok, %{outcome: :completed} = original} = Operation.await(established, timeout: 800)
      gate = hold_first_chunk(roles.router, endpoint.epoch, roles.guardian, :permanent)
      watch_queued_tail(roles.guardian, gate)
      watch_manager_drain(endpoint.manager, endpoint.epoch, roles.guardian, gate)
      guardian = :sys.get_state(roles.guardian, 500)
      {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
      watcher = watch_native(helper, guardian.child)

      monitors =
        for name <- [:router, :guardian, :epoch_supervisor],
            pid = Map.fetch!(roles, name),
            do: {pid, Process.monitor(pid)}

      outcome =
        try do
          deadline = Deadline.new(800)

          assert {:ok, unfinished} =
                   Control.submit(control, Request.field("@receive_tail"), timeout: 800)

          assert_receive {^gate, :held}, Deadline.remaining(deadline)
          assert_receive {^gate, :tail_queued}, Deadline.remaining(deadline)
          assert :pending = Operation.result(unfinished)
          watch_record_retirement(endpoint.manager, unfinished, gate)
          watch_drain_exit(roles.guardian, gate)
          assert Port.command(watcher, "terminate\n")
          assert %{"kind" => "exited", "milliseconds" => native_ms} = exit = receive_json(watcher)
          IO.puts(JSON.encode!(exit))
          assert native_ms < 750
          assert_receive {^watcher, {:exit_status, 0}}, Deadline.remaining(deadline)
          assert_receive {^gate, :drain_exited}, Deadline.remaining(deadline)

          assert_receive {^gate, :drain_origin, origin, manager_cutoff},
                         Deadline.remaining(deadline)

          draining = :sys.get_state(roles.guardian, 500)
          assert draining.phase == :ready
          assert draining.stdout_chunks >= 2
          assert draining.cleanup_at == origin + 750
          assert manager_cutoff == origin + 800

          IO.puts(
            JSON.encode!(%{
              stage: :queued_drain,
              mode: mode,
              guardian_budget: 750,
              manager_budget: 800
            })
          )

          case mode do
            :expiry -> :ok
            :explicit_close -> assert :ok = Control.request_close(control)
            :router_owner_loss -> Process.exit(roles.router, :kill)
          end

          retirement = %Deadline{expires_at: origin + 950}

          for {pid, monitor} <- monitors do
            assert_receive {:DOWN, ^monitor, :process, ^pid, _}, Deadline.remaining(retirement)
            refute Process.alive?(pid)
          end

          assert_receive {^gate, :record_retired}, Deadline.remaining(retirement)
          assert Deadline.remaining(retirement) > 0
          assert {:ok, ^original} = Operation.result(established)

          assert {:ok, %{outcome: :unknown, certainty: :unknown, evidence: :epoch_closed}} =
                   Operation.result(unfinished)

          if mode == :expiry do
            assert {:error, %LibTmux.Error{kind: :cleanup_unknown, certainty: :unknown}} =
                     Control.close(control, timeout: 100)
          end

          assert OwnedTmux.alive?(fixture)

          IO.puts(
            JSON.encode!(%{
              stage: :drain_aborted,
              mode: mode,
              elapsed_ms: System.monotonic_time(:millisecond) - origin,
              established: :preserved,
              unfinished: :unknown,
              borrowed_server_alive: true
            })
          )

          :ok
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
        end

      cleanup =
        try do
          send(roles.router, {gate, :continue})
          if Port.info(watcher), do: Port.close(watcher)
          cleanup_deadline = Deadline.new(950)

          if Process.alive?(parent),
            do: :sys.terminate(parent, :normal, Deadline.remaining(cleanup_deadline))

          assert_receive {:DOWN, ^root_monitor, :process, ^root, _},
                         Deadline.remaining(cleanup_deadline)

          assert_receive {:DOWN, ^parent_monitor, :process, ^parent, _},
                         Deadline.remaining(cleanup_deadline)

          refute Process.alive?(root)
          assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
          :ok
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
        end

      case {outcome, cleanup} do
        {{:failed, kind, reason, stack}, other} ->
          if other != :ok, do: IO.inspect(other, label: "additional cleanup failure", limit: 8)
          :erlang.raise(kind, reason, stack)

        {:ok, {:failed, kind, reason, stack}} ->
          :erlang.raise(kind, reason, stack)

        {:ok, :ok} ->
          :ok
      end
    end
  end

  defp watch_native(helper, client) do
    watcher =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        {:args,
         [
           Path.join(__DIR__, "support/control_exit.py"),
           Integer.to_string(helper),
           Integer.to_string(client)
         ]}
      ])

    assert %{"kind" => "ready", "helper_sha256" => _, "client_sha256" => _} =
             identity =
             receive_json(watcher)

    IO.puts(JSON.encode!(identity))
    watcher
  end

  defp receive_json(port) do
    receive do
      {^port, {:data, {:eol, data}}} -> JSON.decode!(data)
      {^port, {:exit_status, status}} -> flunk("owned exit observer failed: #{status}")
    after
      950 -> flunk("owned exit observer did not respond")
    end
  end

  defp hold_first_chunk(router, epoch, guardian, mode \\ :bounded) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(router, {
        fn
          _seen, {:in, {:guardian, ^epoch, ^guardian, {:stdout, _bytes, _credit}}}, _name ->
            send(observer, {token, :held})

            case mode do
              :permanent ->
                receive do
                  {^token, :continue} -> :done
                end

              :bounded ->
                receive do
                  {^token, :continue} -> :done
                after
                  800 -> raise "receive observation gate was not released"
                end
            end

          seen, _event, _name ->
            seen
        end,
        false
      })

    token
  end

  defp watch_manager_drain(manager, epoch, guardian, token) do
    observer = self()

    :ok =
      :sys.install(
        manager,
        {fn
           _seen, {:in, {:guardian, ^epoch, ^guardian, {:draining, origin}}}, _name ->
             origin

           origin, {:noreply, state}, _name when is_integer(origin) ->
             send(observer, {token, :drain_origin, origin, state.closing_at})
             :done

           seen, _event, _name ->
             seen
         end, false}
      )
  end

  defp watch_record_retirement(manager, operation, token) do
    observer = self()

    :ok =
      :sys.install(
        manager,
        {fn
           seen, {:noreply, _state}, _name ->
             case Operation.status(operation) do
               {:ok, %{wire: :retired}} ->
                 send(observer, {token, :record_retired})
                 :done

               _ ->
                 seen
             end

           seen, _event, _name ->
             seen
         end, false}
      )
  end

  defp watch_waiter(manager, receiver, token) do
    observer = self()

    :ok =
      :sys.install(manager, {
        fn
          seen, {:noreply, state}, _name ->
            if Enum.any?(Map.values(state.waiters.active), &(&1.ticket.caller == receiver)) do
              send(observer, {token, :registered})
              :done
            else
              seen
            end

          seen, _event, _name ->
            seen
        end,
        false
      })
  end

  defp watch_queued_tail(guardian, token) do
    observer = self()

    :ok =
      :sys.install(guardian, {
        fn
          seen, {:noreply, %{phase: :ready, stdout_queue: queue}}, _name ->
            bytes = IO.iodata_to_binary(:queue.to_list(queue))

            if :binary.match(bytes, "\n%end ") != :nomatch and String.ends_with?(bytes, " 1\n") do
              send(observer, {token, :tail_queued})
              :done
            else
              seen
            end

          seen, _event, _name ->
            seen
        end,
        false
      })
  end

  defp watch_drain_exit(guardian, token) do
    observer = self()

    :ok =
      :sys.install(guardian, {
        fn
          _seen, {:noreply, %{phase: :ready, drain: %{exit_status: 0}}}, _name ->
            send(observer, {token, :drain_exited})
            :done

          seen, _event, _name ->
            seen
        end,
        false
      })
  end
end
