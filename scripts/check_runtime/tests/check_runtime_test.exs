# Run with: elixir scripts/check_runtime/tests/check_runtime_test.exs
#
# The runtime check names the profiles it accepts, and the custom one asserts
# nothing.

ExUnit.start()

defmodule CheckRuntimeTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @script Path.expand("../check_runtime.exs", __DIR__)

  defp check(arguments),
    do: System.cmd("elixir", [@script | arguments], cd: @root, stderr_to_stdout: true)

  test "the custom profile prints the runtime identity and asserts nothing" do
    {output, 0} = check(["custom"])
    identity = JSON.decode!(String.trim(output))

    assert identity["profile"] == "custom"
    assert identity |> Map.keys() |> Enum.sort() == ["compiled_otp", "elixir", "otp", "profile"]
    assert identity["elixir"] == System.version()
  end

  test "an unknown profile is refused" do
    {output, status} = check(["everything"])
    assert status != 0
    assert output =~ "expected reference, tracking or custom"
  end

  test "a missing profile is refused" do
    assert {_output, status} = check([])
    assert status != 0
  end
end
