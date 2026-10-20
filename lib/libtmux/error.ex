defmodule LibTmux.Error do
  @moduledoc """
  An inspectable failure with its phase and certainty about effects.

  `retryable` describes a recovery option; it never authorizes replay of a
  mutation. Diagnostic details must stay within the producing operation's
  byte budget. Bang functions raise this same structure.
  """

  defexception [
    :kind,
    phase: :validation,
    certainty: :unknown,
    retryable: false,
    path: [],
    details: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom(),
          phase: atom(),
          certainty: :no_write | :acknowledged | :observed | :unknown,
          retryable: boolean(),
          path: [atom() | String.t() | non_neg_integer()],
          details: map()
        }

  @impl true
  def message(%__MODULE__{kind: kind, phase: phase, path: path}) do
    location = if path == [], do: "", else: " at #{inspect(path)}"
    "#{kind} during #{phase}#{location}"
  end
end
