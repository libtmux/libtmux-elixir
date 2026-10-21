defmodule LibTmux.CompilerExamples.DependentCodec do
  def upcase_number do
    {:ok, number} = LibTmux.Codec.decode_field("1\n", :integer)
    String.upcase(number)
  end
end
