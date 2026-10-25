defmodule LibTmux.QuickstartExampleTest do
  use ExUnit.Case, async: true

  @example Path.expand("../examples/quickstart.exs", __DIR__)
  @columns 80

  test "requires any 0.1.N release" do
    [install | _] = @example |> File.read!() |> String.split("\n")

    assert install == ~s|Mix.install([{:libtmux, "~> 0.1"}])|
  end

  test "fits the 80-column display of published examples" do
    source = File.read!(@example)

    assert too_wide(source) == []
    refute String.contains?(source, "\t")

    # Control: the same check reports a line one column past the limit.
    exact = String.duplicate("x", @columns)
    over = String.duplicate("x", @columns + 1)
    assert [{2, ^over}] = too_wide(exact <> "\n" <> over)
  end

  defp too_wide(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      if String.length(line) > @columns, do: [{number, line}], else: []
    end)
  end
end
