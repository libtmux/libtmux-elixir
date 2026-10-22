defmodule LibTmux.ControlColdStartupIntegrationTest do
  use ExUnit.Case,
    async: true,
    parameterize: [%{entry: "supervisor"}, %{entry: "connection"}]

  alias LibTmux.Control.SupervisorStart
  alias LibTmux.Transport.OneShot

  @moduletag :integration
  @moduletag reason: "Gates the code loader only inside a bounded, owned child VM"

  test "cold reply cleanup returns after exact Root exit without the loader", %{entry: entry} do
    paths = Path.dirname(:code.which(SupervisorStart) |> to_string())
    script = Path.join(__DIR__, "support/cold_startup_reply.exs")
    environment = Map.take(System.get_env(), ["PATH", "ERL_FLAGS", "LANG", "LC_ALL"])

    assert {:ok, result} =
             OneShot.run(System.find_executable("elixir"), ["-pa", paths, script, entry],
               env: environment,
               max_stdout_bytes: 8192,
               max_stderr_bytes: 8192
             )

    assert result.cleanup == :retired
    assert result.exit_status == 0, result.stdout <> result.stderr

    assert %{
             "status" => "PASS",
             "root_exit" => "killed",
             "caller_exit" => "normal",
             "reply_loaded_during_gate" => false,
             "code_server_suspended" => true,
             "root_gate_confirmed" => true,
             "return_observed_in_budget" => true
           } =
             JSON.decode!(result.stdout)
  end
end
