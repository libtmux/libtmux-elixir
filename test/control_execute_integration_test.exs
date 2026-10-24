defmodule LibTmux.ControlExecuteIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Operation, Server}
  alias LibTmux.Control.{Admission, Births, ExecutionError}
  alias LibTmux.Control.Request
  alias LibTmux.Test.OwnedTmux
  @moduletag :integration
  @moduletag reason:
               "Qualifies managed result reclamation against owned tmux at default and single-slot capacity"

  test "caller death reclaims after the operation retires and timeout leaves inspectable work" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: info.socket)

    {:ok, root, control} =
      Control.start_link(
        server: server,
        session: {:existing, "$0"},
        lane: :host_qualified,
        timeout: 800,
        capacity: 1,
        waiter_capacity: 1
      )

    root_monitor = Process.monitor(root)
    {:ok, %{roles: roles}} = Births.snapshot(control.endpoint.births)
    observer = self()
    assert :ok = :sys.suspend(roles.router, 500)

    {caller, monitor} =
      spawn_monitor(fn ->
        receive do
          :execute ->
            Control.execute(control, Request.set_user_option("@orphan", "finished"), timeout: 800)
        end
      end)

    token = make_ref()

    :ok =
      :sys.install(
        control.endpoint.manager,
        {token,
         fn
           :new, {:noreply, state}, _ ->
             if Enum.any?(Map.values(state.waiters.active), &(&1.ticket.caller == caller)) do
               send(observer, {token, :registered})
               :registered
             else
               :new
             end

           :registered, {:noreply, state}, _ ->
             if Admission.entries(state.pool) == {:ok, []} and state.waiters.publishers == %{} do
               send(observer, {token, :reclaimed})
               :done
             else
               :registered
             end

           previous, _, _ ->
             previous
         end, :new},
        500
      )

    try do
      send(caller, :execute)
      assert_receive {^token, :registered}, 750
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 100
      assert :ok = :sys.resume(roles.router, 500)
      assert_receive {^token, :reclaimed}, 750
      assert {"finished\n", 0} = OwnedTmux.command(fixture, ["show-options", "-sv", "@orphan"])

      assert {:ok, %{outcome: :completed}} =
               Control.execute(control, Request.field("pid"), timeout: 800)

      assert :ok = :sys.suspend(roles.router, 500)

      [{1, previous}] = :ets.lookup(control.endpoint.waiter_inbox.table, 1)
      released = make_ref()

      assert :ok =
               :sys.install(
                 control.endpoint.manager,
                 {released,
                  fn
                    false, {:noreply, state}, _ ->
                      [{1, receipt}] = :ets.lookup(state.waiters.inbox.table, 1)

                      if receipt.generation > previous.generation and
                           receipt.state in [:free, :done] do
                        send(observer, {released, :collector_released})
                        true
                      else
                        false
                      end

                    sent, _, _ ->
                      sent
                  end, false},
                 500
               )

      assert {:error,
              %ExecutionError{context: :retained, operation: operation, error: %{kind: :timeout}}} =
               Control.execute(control, Request.set_user_option("@timed_out", "unwritten"),
                 timeout: 30
               )

      assert :ok = :sys.resume(roles.router, 500)
      assert_receive {^released, :collector_released}, 750

      assert {:ok, %{outcome: :skipped, certainty: :no_write}} =
               Operation.await(operation, timeout: 800)

      assert {_, 1} = OwnedTmux.command(fixture, ["show-options", "-sv", "@timed_out"])
    after
      Process.exit(caller, :kill)
      if Process.alive?(roles.router), do: :sys.resume(roles.router, 500)
      assert :ok = Control.close(control, timeout: 800)
      assert :ok = :sys.terminate(root, :normal, 750)
      assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}, 100
    end

    assert OwnedTmux.alive?(fixture)

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end

  test "128 sequential executions reclaim operation and receipt capacity before returning" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: info.socket)

    for limits <- [[], [capacity: 1, waiter_capacity: 1, metadata_capacity: 1]] do
      {:ok, root, control} =
        Control.start_link(
          [server: server, session: {:existing, "$0"}, lane: :host_qualified, timeout: 800] ++
            limits
        )

      root_monitor = Process.monitor(root)

      try do
        for index <- 1..128 do
          assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
                   Control.execute(control, Request.set_user_option("@managed", "#{index}"),
                     timeout: 800
                   )
        end

        assert {"128\n", 0} = OwnedTmux.command(fixture, ["show-options", "-sv", "@managed"])
        [{:connection, endpoint}] = :ets.lookup(control.view, :connection)
        assert :ets.info(endpoint.pool.table, :size) == endpoint.pool.capacity + 1
        assert :ets.info(endpoint.records.table, :size) == endpoint.pool.capacity + 1
        assert :ets.info(endpoint.waiter_inbox.table, :size) == endpoint.waiter_inbox.capacity + 1

        assert Enum.all?(:ets.tab2list(endpoint.records.table), fn
                 {:context, _} -> true
                 {_, nil} -> true
                 _ -> false
               end)
      after
        assert :ok = Control.close(control, timeout: 800)
        assert :ok = :sys.terminate(root, :normal, 750)
        assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}, 100
      end
    end

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end
end
