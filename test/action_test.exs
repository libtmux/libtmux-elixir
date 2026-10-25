defmodule LibTmux.ActionTest do
  use ExUnit.Case, async: true
  alias LibTmux.Action
  alias LibTmux.Action.CompletionError

  @completed %{
    outcome: :completed,
    certainty: :acknowledged,
    evidence: :command_reply,
    transport: :control,
    value: :ok,
    details: %{}
  }

  test "completion preserves values without interpreting them" do
    for value <- [:ok, "%7", <<0, 255>>, nil, %{id: "%7"}] do
      assert Action.unwrap({:ok, %{@completed | value: value}}) === value
    end
  end

  test "unsuccessful outcomes preserve the complete original evidence" do
    for {outcome, certainty, evidence, transport} <- [
          {:failed, :observed, :process_exit, :one_shot},
          {:failed, :acknowledged, :command_reply, :control},
          {:skipped, :no_write, :timeout, :control},
          {:unknown, :unknown, :epoch_closed, :control}
        ] do
      result = %{
        outcome: outcome,
        certainty: certainty,
        evidence: evidence,
        transport: transport,
        value: nil,
        details: %{output: String.duplicate("private bytes", 1000)},
        extra_evidence: make_ref()
      }

      error = %CompletionError{result: result}
      assert assert_raise(CompletionError, fn -> Action.unwrap({:error, error}) end) === error
      assert error.result === result
      message = Exception.message(error)
      assert message =~ inspect(outcome)
      assert message =~ inspect(certainty)
      assert message =~ inspect(transport)
      refute message =~ "private bytes"
      assert byte_size(message) < 128
    end
  end

  test "API refusals preserve the original exception" do
    error = %LibTmux.Error{
      kind: :invalid_command,
      phase: :validation,
      certainty: :no_write,
      path: [:options, :size],
      details: %{reason: "expected a percent in 1..99"}
    }

    assert assert_raise(LibTmux.Error, fn -> Action.unwrap({:error, error}) end) === error
  end
end
