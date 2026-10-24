defmodule LibTmux.Control.ExecutionError do
  @moduledoc """
  A managed execution reported an error after admission.

  `error` explains the wait or context failure. `operation` is the exact
  admitted handle. `context` reports whether its record was retained when
  inspected; expiry, Manager loss or death of the original `execute/3` caller
  can invalidate it later. Passing the handle to another process does not
  transfer recovery ownership; use `Control.submit/3` for durable retention
  independent of the submitting caller. `:lost` never
  establishes that the command was unwritten and does not authorize replay.
  Inspect a retained handle with `LibTmux.Operation.status/1` before leaving
  its owning scope. See the [recovery example](recovery.html).
  """
  defexception [:error, :operation, :context]
  @typedoc "Recovery evidence after admission; the original operation deadline is unchanged."
  @type t :: %__MODULE__{
          error: LibTmux.Error.t(),
          operation: LibTmux.Operation.t(),
          context: :retained | :lost
        }

  @impl true
  def message(exception),
    do: "managed execution #{exception.error.kind}; operation context #{exception.context}"
end
