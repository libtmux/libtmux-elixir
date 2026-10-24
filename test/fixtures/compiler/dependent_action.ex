defmodule LibTmux.CompilerExamples.DependentAction do
  def pane_id(connection, pane) do
    {:ok, result} = LibTmux.Pane.split(connection, pane)
    String.upcase(result.value.id)
  end
end
