defmodule LibTmux.ControlScopeIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux
  @moduletag :integration
  @moduletag reason:
               "Qualifies scoped connection cleanup after return, callback exceptions and caller death"

  test "scope retires the current epoch after an explicit callback reconnect" do
    fixture = start_supervised!({OwnedTmux, []})

    assert {:ok, :reconnected} =
             Control.with_connection(options(fixture), fn original ->
               assert :ok = Control.close(original, timeout: 800)
               assert {:ok, replacement} = Control.reconnect(original, timeout: 800)
               assert {:error, %{kind: :stale_connection}} = Control.status(original)
               watch(replacement)
               :reconnected
             end)

    assert_retired()

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  test "callback values stay in the caller and all normal and exceptional exits retire the connection" do
    fixture = start_supervised!({OwnedTmux, []})
    options = options(fixture)
    caller = self()
    value = fn -> :caller_value end

    assert {:ok, ^value} =
             Control.with_connection(options, fn control ->
               assert self() == caller

               assert {:ok, %{outcome: :completed}} =
                        Control.execute(control, Request.field("pid"), timeout: 800)

               watch(control)
               value
             end)

    assert_retired()

    assert_raise RuntimeError, "callback failed", fn ->
      Control.with_connection(options, fn control ->
        watch(control)
        raise "callback failed"
      end)
    end

    assert_retired()

    assert catch_throw(
             Control.with_connection(options, fn control ->
               watch(control)
               throw(:callback_throw)
             end)
           ) == :callback_throw

    assert_retired()

    assert catch_exit(
             Control.with_connection(options, fn control ->
               watch(control)
               exit(:callback_exit)
             end)
           ) == :callback_exit

    assert_retired()

    assert {:error, %{kind: :command_error}} =
             Control.with_connection(
               Keyword.put(options, :session, {:existing, "$999999"}),
               fn _ -> flunk("failed startup invoked callback") end
             )

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  test "a dead callback caller leaves its connection owner responsible for native retirement" do
    fixture = start_supervised!({OwnedTmux, []})
    options = options(fixture)
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        Control.with_connection(options, fn control ->
          send(observer, {:control, control})

          receive do
            :never -> :unreachable
          end
        end)
      end)

    assert_receive {:control, control}, 800
    watch(control)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 100
    assert_retired()

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  @tag capture_log: true
  test "cleanup loss preserves the callback value or exception instead of replacing it" do
    fixture = start_supervised!({OwnedTmux, []})
    options = options(fixture)

    for mode <- [:return, :raise] do
      outcome =
        Control.with_connection(options, fn control ->
          watch(control)
          root = control.owner
          monitor = Process.monitor(root)
          Process.exit(root, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, 100
          if mode == :raise, do: throw(:primary), else: :primary
        end)

      assert {:error,
              %{
                __struct__: LibTmux.Control.ScopeFailure,
                primary: primary,
                cleanup: %{certainty: :unknown}
              }} = outcome

      if mode == :return,
        do: assert(primary == {:return, :primary}),
        else: assert(match?({:raise, :throw, :primary, [_ | _]}, primary))

      assert_retired()
    end

    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp options(fixture) do
    info = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")

    [
      server: Server.new(executable: executable, socket: info.socket),
      session: {:existing, "$0"},
      lane: :host_qualified,
      timeout: 800
    ]
  end

  defp watch(control) do
    {:ok, %{roles: roles}} = Births.snapshot(control.endpoint.births)
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)
    native = OwnedTmux.watch_processes([helper, guardian.child])
    {:dictionary, dictionary} = Process.info(control.owner, :dictionary)
    [scope_owner | _] = Keyword.fetch!(dictionary, :"$ancestors")
    actors = [scope_owner, control.owner, control.endpoint.manager | Map.values(roles)]
    send(self(), {:retirement, native, for(pid <- actors, do: {pid, Process.monitor(pid)})})
  end

  defp assert_retired do
    assert_receive {:retirement, native, monitors}, 100
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 750)
    assert :ok = OwnedTmux.await_exit(native)
  end
end
