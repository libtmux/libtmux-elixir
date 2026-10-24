defmodule LibTmux.ActionTest do
  use ExUnit.Case, async: true
  alias LibTmux.Action
  alias LibTmux.Action.CompletionError

  doctest Action

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
      assert Action.value!(%{@completed | value: value}) === value
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

      error = assert_raise CompletionError, fn -> Action.value!(result) end
      assert error.result === result
      message = Exception.message(error)
      assert message =~ inspect(outcome)
      assert message =~ inspect(certainty)
      assert message =~ inspect(transport)
      refute message =~ "private bytes"
      assert byte_size(message) < 128
    end
  end

  test "non-action results are rejected without manufacturing an outcome" do
    for invalid <- [
          nil,
          {:ok, @completed},
          {:error, %LibTmux.Error{kind: :invalid_target}},
          Map.drop(@completed, [:value]),
          Map.drop(@completed, [:details]),
          %{@completed | outcome: :pending},
          %{@completed | certainty: :certain},
          %{@completed | evidence: "command_reply"},
          %{@completed | transport: :implicit},
          %{@completed | details: []},
          %{@completed | outcome: :failed, value: "%7"}
        ] do
      assert_raise ArgumentError, "expected a bare LibTmux.Action result", fn ->
        Action.value!(invalid)
      end
    end

    assert Exception.message(%CompletionError{result: nil}) ==
             "expected a completed action outcome"
  end
end
