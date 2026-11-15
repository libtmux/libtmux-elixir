defmodule LibTmux.RecoveryExampleIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.TmuxPath
  alias LibTmux.Transport.OneShot

  @moduletag :integration
  @moduletag reason:
               "Runs the recovery example through real admission, owner loss and cleanup faults"

  test "the application retains execution and cleanup evidence in its original caller" do
    tmp = TmuxPath.private_directory(System.tmp_dir!(), "ltx-recovery")
    on_exit(fn -> File.rm_rf!(tmp) end)
    env = TmuxPath.environment(TmuxPath.executable(), Path.join(tmp, "bin"), tmp)
    ebin = :code.which(LibTmux.Control) |> List.to_string() |> Path.dirname()

    assert {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
             OneShot.run(
               System.find_executable("elixir"),
               [
                 "-pa",
                 ebin,
                 Path.join(__DIR__, "support/recovery_cases.exs"),
                 Path.expand("../examples/recover_command.exs", __DIR__)
               ],
               timeout: 10_000,
               env: env
             )

    [normal, faults] = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert normal == %{"recovery_example" => "completed", "connection_retired" => true}

    assert faults == %{
             "recovery_cases" => "ok",
             "inspected_before_scope_exit" => true,
             "native_exited" => true
           }

    # The example and the fault cases each owned a server, and both are gone.
    assert File.ls!(tmp) == ["bin"]
  end
end
