defmodule LibTmux.ControlTargetIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Codec, Control, Operation, Ref, Server}
  alias LibTmux.Control.{Births, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason: "Qualifies exact target disappearance over a real control connection"

  test "disappeared targets fail while existing empty fields remain successful" do
    fixture = start_supervised!({OwnedTmux, []})
    info = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: info.socket, cwd: "/", env: %{})

    assert {ids, 0} =
             OwnedTmux.command(fixture, [
               "new-session",
               "-d",
               "-s",
               "target",
               "-P",
               "-F",
               ~S"#{session_id} #{window_id} #{pane_id} #{pane_pid}"
             ])

    [session_id, window_id, pane_id, pane_pid] = String.split(ids)

    assert {:ok, root, control} =
             Control.start_link(
               server: server,
               session: {:existing, "$0"},
               lane: :host_qualified,
               timeout: 800
             )

    root_monitor = Process.monitor(root)
    [{:connection, endpoint}] = :ets.lookup(control.view, :connection)
    {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    actors = Enum.map(roles, fn {_role, pid} -> {pid, Process.monitor(pid)} end)
    fixture_exit = OwnedTmux.watch_exit(info)

    try do
      assert {:ok, %{instance: instance}} = Control.status(control)

      targets =
        for {entity, id} <- [session: session_id, window: window_id, pane: pane_id] do
          assert {:ok, target} = Ref.new(entity, id, instance)
          field = Atom.to_string(entity) <> "_id"

          assert %{outcome: :completed, certainty: :acknowledged, lines: [encoded]} =
                   read(control, field, target)

          assert {:ok, ^id} = Codec.decode_field(encoded <> "\n", :string, encoding: :escaped_v1)

          assert %{outcome: :completed, certainty: :acknowledged, lines: ["v1:"]} =
                   read(control, "@missing_target_option", target)

          {target, field}
        end

      target_exit = OwnedTmux.watch_processes([String.to_integer(pane_pid)])
      assert {_, 0} = OwnedTmux.command(fixture, ["kill-session", "-t", session_id])
      assert :ok = OwnedTmux.await_exit(target_exit)

      for {target, field} <- targets do
        assert %{outcome: :failed, certainty: :acknowledged} = read(control, field, target)
        assert {:ok, %{phase: :ready}} = Control.status(control)
      end

      assert %{outcome: :completed, certainty: :acknowledged} = read(control, "pid", nil)
    after
      try do
        assert :ok = Control.close(control, timeout: 800)

        for {pid, monitor} <- actors do
          assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 850
          refute Process.alive?(pid)
        end

        assert :ok = :sys.terminate(root, :normal, 500)
        assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}, 100
      after
        survived = OwnedTmux.alive?(fixture)
        cleanup = OwnedTmux.close(fixture)
        assert :ok = OwnedTmux.await_exit(fixture_exit)
        assert survived
        assert {:ok, %{pane_exited: true, clients_exited: true}} = cleanup
      end
    end
  end

  defp read(control, field, target) do
    assert {:ok, operation} = Control.submit(control, Request.field(field, target), timeout: 800)
    assert {:ok, result} = Operation.await(operation, timeout: 800)
    assert :ok = Operation.forget(operation, timeout: 800)
    result
  end
end
