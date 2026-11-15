# Keeps every displayed program identical to its executable example.
#
# Usage: elixir scripts/check_example_docs/check_example_docs.exs [--write]
#
# Run from the repository root. Each `<!-- example: examples/NAME.exs -->` block
# in README.md and docs/*.md must hold the exact source of that file, or of the
# `# docs:begin REGION` to `# docs:end REGION` part of it when the marker names
# one as `examples/NAME.exs#REGION`. Every examples/*.exs file must be shown
# somewhere. `--write` rewrites the displayed copies instead of failing.

defmodule ExampleDocs do
  @moduledoc false

  @block ~r/(<!-- example: (examples\/[a-z_]+\.exs)(?:#([a-z_]+))? -->\n\n```elixir\n)(.*?)(```\n\n<!-- \/example -->)/s

  @doc "Checks (or with `write: true`, rewrites) the guides under `root`; returns the programs shown."
  def run(root, options \\ []) do
    write? = Keyword.get(options, :write, false)

    guides =
      [Path.join(root, "README.md") | Enum.sort(Path.wildcard(Path.join(root, "docs/*.md")))]

    shown =
      for guide <- guides, text = File.read!(guide), reduce: MapSet.new() do
        shown ->
          updated = replace(text, guide, root, write?)
          if write? and updated != text, do: File.write!(guide, updated)
          shown |> MapSet.union(sources(text))
      end

    all =
      root
      |> Path.join("examples/*.exs")
      |> Path.wildcard()
      |> MapSet.new(&Path.relative_to(&1, root))

    case MapSet.difference(all, shown) |> Enum.sort() do
      [] -> MapSet.size(shown)
      missing -> raise "Examples without displayed source: #{inspect(missing)}"
    end
  end

  defp sources(text) do
    @block
    |> Regex.scan(text, capture: :all_but_first)
    |> MapSet.new(fn [_head, source | _] -> source end)
  end

  defp replace(text, guide, root, write?) do
    Regex.replace(@block, text, fn _whole, head, source, region, displayed, tail ->
      expected = expected(root, source, region)

      if displayed != expected and not write? do
        raise "#{Path.relative_to(guide, root)}: #{source} drifted; " <>
                "run elixir scripts/check_example_docs/check_example_docs.exs --write"
      end

      head <> expected <> tail
    end)
  end

  defp expected(root, source, region) do
    text = File.read!(Path.join(root, source))

    if region == "" do
      text
    else
      pattern = ~r/^[ \t]*# docs:begin #{region}\n(.*?)^[ \t]*# docs:end #{region}$/ms

      case Regex.scan(pattern, text, capture: :all_but_first) do
        [[snippet]] -> dedent(snippet)
        _ -> raise "#{source}: expected one example region #{region}"
      end
    end
  end

  # Removes the indentation every non-blank line shares; blank lines become empty.
  defp dedent(text) do
    lines = String.split(text, "\n")

    margin =
      lines
      |> Enum.reject(&blank?/1)
      |> Enum.map(&indentation/1)
      |> Enum.min(fn -> 0 end)

    Enum.map_join(lines, "\n", fn line ->
      if blank?(line), do: "", else: binary_part(line, margin, byte_size(line) - margin)
    end)
  end

  defp blank?(line), do: String.match?(line, ~r/\A[ \t]*\z/)
  defp indentation(line), do: line |> then(&Regex.run(~r/\A[ \t]*/, &1)) |> hd() |> byte_size()

  def main(arguments) do
    write? = "--write" in arguments

    try do
      count = run(File.cwd!(), write: write?)
      IO.puts("PASS: #{count} displayed programs match executable sources")
    rescue
      error in RuntimeError ->
        IO.puts(:stderr, error.message)
        System.halt(1)
    end
  end
end

if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: ExampleDocs.main(System.argv())
