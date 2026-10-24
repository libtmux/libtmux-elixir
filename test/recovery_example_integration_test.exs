defmodule LibTmux.RecoveryExampleIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.Test.OwnedTmux
  alias LibTmux.Transport.OneShot

  @moduletag :integration
  @moduletag reason:
               "Runs the recovery example through real admission, owner loss and cleanup faults"

  test "the application retains execution and cleanup evidence in its original caller" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    ebin = :code.which(LibTmux.Control) |> List.to_string() |> Path.dirname()

    assert {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
             OneShot.run(
               System.find_executable("elixir"),
               [
                 "-pa",
                 ebin,
                 Path.join(__DIR__, "support/recovery_cases.exs"),
                 Path.expand("../examples/recover_command.exs", __DIR__),
                 executable,
                 socket,
                 "$0"
               ],
               timeout: 5000,
               env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
             )

    [normal, faults] = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert normal == %{"recovery_example" => "completed", "connection_retired" => true}

    assert faults == %{
             "recovery_cases" => "ok",
             "inspected_before_scope_exit" => true,
             "native_exited" => true
           }

    assert OwnedTmux.alive?(fixture)

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end
end
