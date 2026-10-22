defmodule LibTmux.CompilerExamples.InvalidReference do
  def width do
    {:ok, ref} = LibTmux.Ref.new(:pane, "%0", "compiler-fixture")
    ref.width
  end
end
