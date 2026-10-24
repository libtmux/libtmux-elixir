defmodule LibTmux.CompilerExamples.InvalidReference do
  def width do
    pane = %LibTmux.Pane{id: "%0", server_instance: "compiler-fixture"}
    {:ok, ref} = LibTmux.Ref.from_observation(pane)
    ref.width
  end
end
