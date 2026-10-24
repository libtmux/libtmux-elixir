defmodule LibTmux.Action.CompletionError do
  @moduledoc """
  An action result did not meet an explicit completion requirement.

  Raised by domain bang actions such as `LibTmux.Pane.split!/3`. `result`
  preserves the original
  failed, skipped or unknown outcome, including certainty and transport
  evidence. An unknown outcome remains unknown; this exception does not
  cancel work or authorize replay. Its message omits transport output.
  """

  defexception [:result]

  @typedoc "The original action result that did not establish command completion."
  @type t :: %__MODULE__{result: LibTmux.Action.result(term())}

  @impl true
  def message(%{result: %{outcome: outcome, certainty: certainty, transport: transport}})
      when outcome in [:failed, :skipped, :unknown] and
             certainty in [:acknowledged, :observed, :no_write, :unknown] and
             transport in [:one_shot, :control],
      do:
        "action outcome #{inspect(outcome)} (#{inspect(certainty)}, #{inspect(transport)}); expected :completed"

  def message(_exception), do: "expected a completed action outcome"
end
