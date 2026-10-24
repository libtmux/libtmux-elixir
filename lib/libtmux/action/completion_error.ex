defmodule LibTmux.Action.CompletionError do
  @moduledoc """
  An action result did not meet an explicit completion requirement.

  Returned in an error tuple by domain actions such as `LibTmux.Pane.split/3`
  and raised by their bang variants. `result` preserves the original
  failed, skipped or unknown outcome, including certainty and transport
  evidence. An unknown outcome remains unknown; this exception does not
  cancel work or authorize replay. Its message omits transport output.
  """

  defexception [:result]

  @typedoc "The original action result that did not establish command completion."
  @type t :: %__MODULE__{result: LibTmux.Action.unsuccessful_result()}

  @impl true
  def message(%{result: %{outcome: outcome, certainty: certainty, transport: transport}})
      when outcome in [:failed, :skipped, :unknown] and
             certainty in [:acknowledged, :observed, :no_write, :unknown] and
             transport in [:one_shot, :control],
      do:
        "action outcome #{inspect(outcome)} (#{inspect(certainty)}, #{inspect(transport)}); expected :completed"

  def message(_exception), do: "expected a completed action outcome"
end
