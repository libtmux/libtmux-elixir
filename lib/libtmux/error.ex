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

  @typedoc "Evidence about effects, independent of whether cleanup or arbitrary program completion is proved."
  @type certainty :: :no_write | :acknowledged | :observed | :unknown
  @typedoc "A field, array index or observed identity locating an error; links retain their contextual tuple ID."
  @type path_component :: atom() | non_neg_integer() | LibTmux.Ref.id()
  @typedoc "A structured API failure. Kind and phase are extensible; retryable never permits automatic mutation replay."
  @type t :: %__MODULE__{
          kind: atom(),
          phase: atom(),
          certainty: certainty(),
          retryable: boolean(),
          path: [path_component()],
          details: map()
        }

  @impl true
  def message(%__MODULE__{kind: kind, phase: phase, path: path}) do
    location = if path == [], do: "", else: " at #{inspect(path)}"
    "#{kind} during #{phase}#{location}"
  end
end
