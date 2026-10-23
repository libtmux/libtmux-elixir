defmodule LibTmux.Control.ScopeFailure do
  @moduledoc """
  A scoped callback finished, but connection cleanup was not proved.

  `primary` preserves either `{:return, value}` or
  `{:raise, kind, reason, stacktrace}`. `cleanup` holds the separate structured
  cleanup error. Callback values stay in the calling process; this wrapper
  does not copy them through a bounded connection mailbox or discard them.
  See `LibTmux.Control.with_connection/2` for the complete return contract.
  """
  defexception [:primary, :cleanup]

  @typedoc "The callback's original value or caught exception, throw or exit with its stacktrace."
  @type primary(value) :: {:return, value} | {:raise, :error | :throw | :exit, term(), list()}
  @typedoc "Both primary callback evidence and unproved cleanup; neither implies no command effects."
  @type t(value) :: %__MODULE__{primary: primary(value), cleanup: LibTmux.Error.t()}

  @impl true
  def message(exception), do: "scoped connection cleanup failed: #{exception.cleanup.kind}"
end
