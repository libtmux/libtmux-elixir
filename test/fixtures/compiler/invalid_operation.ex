defmodule LibTmux.CompilerExamples.InvalidOperation do
  def exit_status(%LibTmux.Control{} = control) do
    {:ok, operation} = LibTmux.Control.submit(control, LibTmux.Control.Request.field("pid"))
    operation.exit_status
  end
end
