defmodule LibTmux.OwnedTmuxTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason: "Proves real tmux startup, socket isolation and OS process exit"

  test "fixture cleanup reaps its server and pane without affecting another fixture" do
    first = start_supervised!({OwnedTmux, []}, id: :first)
    second = start_supervised!({OwnedTmux, []}, id: :second)
    first_info = OwnedTmux.info(first)
    second_info = OwnedTmux.info(second)

    refute first_info.socket == second_info.socket
    assert {pid, 0} = OwnedTmux.command(first, ["display-message", "-p", ~S"#{pid}"])
    assert String.trim(pid) == Integer.to_string(first_info.server_pid)
    assert {:ok, %{server_exit: 0, pane_exited: true}} = OwnedTmux.close(first)
    assert {:ok, %{server_exit: 0, pane_exited: true}} = OwnedTmux.close(first)

    assert {"fixture\n", 0} =
             OwnedTmux.command(second, ["list-sessions", "-F", ~S"#{session_name}"])

    assert {:ok, %{server_exit: 0, pane_exited: true}} = OwnedTmux.close(second)
  end

  test "an abruptly killed fixture owner still releases its OS processes" do
    fixture =
      start_supervised!(%{
        id: :crashing_fixture,
        start: {OwnedTmux, :start_link, [[]]},
        restart: :temporary
      })

    watcher = fixture |> OwnedTmux.info() |> OwnedTmux.watch_exit()

    capture_log(fn ->
      Process.exit(fixture, :kill)
      assert :ok = OwnedTmux.await_exit(watcher)
    end)
  end
end
