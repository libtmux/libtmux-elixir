[example, executable, socket, session] = System.argv()
System.argv([executable, socket, session])
Code.require_file(example)

unless Code.ensure_loaded?(LibTmux.Test.OwnedTmux),
  do: Code.require_file("owned_tmux.ex", __DIR__)

defmodule LibTmux.Test.RecoveryCases do
  import ExUnit.Assertions
  alias LibTmux.{Command, Control, Error, Ref, Server}
  alias LibTmux.Control.{Births, ExecutionError, Request, ScopeFailure}
  alias LibTmux.Test.OwnedTmux

  def run(executable, socket, session) do
    server = Server.new(executable: executable, socket: socket)
    options = [server: server, session: {:existing, session}, lane: :host_qualified, timeout: 800]

    assert {:ok, :checked} =
             scoped(options, fn control ->
               before = :ets.tab2list(control.endpoint.pool.table)

               assert {:error, {:not_admitted, %Error{certainty: :no_write}}} =
                        inspect_execute(control, Request.field("invalid{"))

               assert :ets.tab2list(control.endpoint.pool.table) == before
               {:ok, %{instance: instance}} = Control.status(control)
               {:ok, absent} = Ref.new(:pane, "%999999", instance)

               assert {:error, {:outcome, %{outcome: :failed, certainty: :acknowledged}}} =
                        inspect_execute(control, Request.field("pane_id", absent))

               assert {:ok, %{outcome: :completed}} =
                        inspect_execute(control, Request.field("pid"))

               :checked
             end)

    request = Request.set_user_option("@recovery_unwritten", "unexpected")

    assert {:ok,
            {:error,
             {:execution, %ExecutionError{context: :retained, error: %{kind: :timeout}},
              {:ok, %{result: nil}}}}} =
             scoped(options, fn control ->
               router = roles(control).router
               :ok = :sys.suspend(router, 500)

               try do
                 inspect_execute(control, request, 30)
               after
                 :ok = :sys.resume(router, 500)
               end
             end)

    assert_unwritten(server)

    for mode <- [:lost, :retained_then_lost] do
      result =
        scoped(options, fn control ->
          :ok = :sys.suspend(roles(control).router, 500)

          if mode == :lost do
            driver = on_registration(control, fn -> kill_root(control) end)
            result = inspect_execute(control, request)
            await_driver(driver)
            result
          else
            {:error, %ExecutionError{context: :retained}} =
              error =
              Control.execute(control, request, timeout: 30)

            kill_root(control)
            CommandRecovery.inspect_execution(error)
          end
        end)

      assert {:error,
              {:cleanup,
               %ScopeFailure{
                 primary: {:return, {:error, {:execution, error, inspection}}},
                 cleanup: %{certainty: :unknown}
               }}} = result

      if mode == :lost do
        assert error.context == :lost
        assert inspection == :lost
      else
        assert error.context == :retained
        assert {:error, %Error{certainty: :unknown}} = inspection
      end

      assert_unwritten(server)
    end

    assert {:ok, {:error, {:outcome, %{outcome: :skipped, certainty: :no_write}}}} =
             scoped(options, fn control ->
               router = roles(control).router
               :ok = :sys.suspend(router, 500)

               driver =
                 on_registration(control, fn ->
                   :ok = Control.request_close(control)
                   :ok = :sys.resume(router, 500)
                 end)

               result = inspect_execute(control, request)
               await_driver(driver)
               result
             end)

    assert_unwritten(server)

    assert {:ok, {:error, {:outcome, %{outcome: :unknown, certainty: :unknown}}}} =
             scoped(options, fn control ->
               router = roles(control).router

               driver =
                 on_state(
                   router,
                   fn state ->
                     Enum.any?(state.operations, fn {_, entry} -> entry.life.wire == :writing end)
                   end,
                   fn -> Process.exit(router, :kill) end
                 )

               result =
                 inspect_execute(control, Request.set_user_option("@recovery_unknown", "once"))

               await_driver(driver)
               result
             end)

    assert {:error,
            {:cleanup,
             %ScopeFailure{
               primary: {:raise, :throw, :primary_failure, [_ | _]},
               cleanup: %{certainty: :unknown}
             }}} =
             scoped(options, fn control ->
               kill_root(control)
               throw(:primary_failure)
             end)

    assert catch_throw(scoped(options, fn _ -> throw(:primary_failure) end)) == :primary_failure

    assert {:error, {:startup, %Error{}}} =
             CommandRecovery.run(Keyword.put(options, :session, {:existing, "$999999"}), fn _ ->
               flunk("failed startup entered callback")
             end)

    assert {:ok, %{stdout: "recorded\n", exit_status: 0}} =
             Server.run(server, Command.new("show-options", ["-sv", "@recovery_example"]))

    assert {:ok, %{stdout: "0\n", exit_status: 0}} =
             Server.run(server, Command.new("display-message", ["-p", ~S"#{session_attached}"]))

    IO.puts(
      JSON.encode!(%{
        recovery_cases: "ok",
        inspected_before_scope_exit: true,
        native_exited: true
      })
    )
  end

  defp inspect_execute(control, request, timeout \\ 500),
    do:
      control |> Control.execute(request, timeout: timeout) |> CommandRecovery.inspect_execution()

  defp scoped(options, callback) do
    try do
      CommandRecovery.run(options, fn control ->
        roles = roles(control)
        guardian = :sys.get_state(roles.guardian, 500)
        {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
        native = OwnedTmux.watch_processes([helper, guardian.child])
        {:dictionary, dictionary} = Process.info(control.owner, :dictionary)
        [scope_owner | _] = Keyword.fetch!(dictionary, :"$ancestors")
        [{:host, host}] = :ets.lookup(control.view, :host)

        actors =
          Enum.uniq([
            scope_owner,
            control.owner,
            host,
            control.endpoint.manager | Map.values(roles)
          ])

        send(self(), {:retirement, native, for(pid <- actors, do: {pid, Process.monitor(pid)})})
        callback.(control)
      end)
    after
      assert_receive {:retirement, native, monitors}, 100
      for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 750)
      assert :ok = OwnedTmux.await_exit(native)
    end
  end

  defp roles(control) do
    {:ok, %{roles: roles}} = Births.snapshot(control.endpoint.births)
    roles
  end

  defp on_registration(control, action) do
    caller = self()

    on_state(
      control.endpoint.manager,
      fn state -> Enum.any?(Map.values(state.waiters.active), &(&1.ticket.caller == caller)) end,
      action
    )
  end

  # Hold the actor at its observed transition until the external fault completes.
  defp on_state(actor, ready?, action) do
    token = make_ref()

    driver =
      spawn_monitor(fn ->
        receive do
          ^token ->
            action.()
            send(actor, {token, :release})
        after
          500 -> raise "fault transition was not observed"
        end
      end)

    :ok =
      :sys.install(
        actor,
        {token,
         fn
           false, {:noreply, state}, _ ->
             if ready?.(state) do
               send(elem(driver, 0), token)

               receive do
                 {^token, :release} -> :ok
               after
                 500 -> raise "fault action did not release its actor"
               end

               true
             else
               false
             end

           previous, _, _ ->
             previous
         end, false},
        500
      )

    driver
  end

  defp kill_root(control) do
    actors = [control.owner, control.endpoint.manager]
    monitors = for pid <- actors, do: {pid, Process.monitor(pid)}
    Process.exit(control.owner, :kill)
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 500)
  end

  defp await_driver({pid, ref}),
    do: assert_receive({:DOWN, ^ref, :process, ^pid, :normal}, 500)

  defp assert_unwritten(server) do
    assert {:error, %Error{kind: :command_error, details: %{exit_status: 1, cleanup: :retired}}} =
             Server.run(server, Command.new("show-options", ["-sv", "@recovery_unwritten"]))
  end
end

Logger.configure(level: :emergency)
LibTmux.Test.RecoveryCases.run(executable, socket, session)
