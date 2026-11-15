# Run with: elixir scripts/check_example_docs/tests/check_example_docs_test.exs
#
# Builds a small repository of examples and guides, then drifts it each way the
# check must notice.

Code.require_file("../check_example_docs.exs", __DIR__)
ExUnit.start()

defmodule CheckExampleDocsTest do
  use ExUnit.Case, async: true

  @script Path.expand("../check_example_docs.exs", __DIR__)

  @whole "IO.puts(\"whole\")\n"
  @regions """
  server = start()

  # docs:begin first
  Enum.each(1..3, fn n ->
    IO.puts(n)
  end)
  # docs:end first
  """

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-docs-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "examples"))
    File.mkdir_p!(Path.join(root, "docs"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "examples/whole.exs"), @whole)

    File.write!(
      Path.join(root, "examples/regions.exs"),
      "defmodule R do\n" <> indent(@regions) <> "end\n"
    )

    {:ok, root: root}
  end

  defp indent(text),
    do: text |> String.split("\n", trim: true) |> Enum.map_join(&("  " <> &1 <> "\n"))

  defp block(source, code),
    do: "<!-- example: #{source} -->\n\n```elixir\n#{code}```\n\n<!-- /example -->\n"

  defp guides(root, whole \\ @whole, region \\ "Enum.each(1..3, fn n ->\n  IO.puts(n)\nend)\n") do
    File.write!(
      Path.join(root, "README.md"),
      "# Readme\n\n" <> block("examples/whole.exs", whole)
    )

    File.write!(Path.join(root, "docs/guide.md"), block("examples/regions.exs#first", region))
  end

  test "displayed programs that match their sources pass, whole file or region", %{root: root} do
    guides(root)
    assert ExampleDocs.run(root) == 2
  end

  test "a region is dedented and its blank lines are emptied", %{root: root} do
    File.write!(
      Path.join(root, "examples/regions.exs"),
      "defmodule R do\n  # docs:begin first\n  a = 1\n\n    b = 2\n  # docs:end first\nend\n"
    )

    guides(root, @whole, "a = 1\n\n  b = 2\n")
    assert ExampleDocs.run(root) == 2
  end

  test "a displayed copy that drifted is named with its guide and source", %{root: root} do
    guides(root, "IO.puts(\"stale\")\n")
    error = assert_raise RuntimeError, fn -> ExampleDocs.run(root) end
    assert error.message =~ "README.md: examples/whole.exs drifted"
    assert error.message =~ "--write"
  end

  test "a drifted region is caught too", %{root: root} do
    guides(root, @whole, "Enum.each(1..3, &IO.puts/1)\n")

    assert_raise RuntimeError, ~r/docs\/guide.md: examples\/regions.exs drifted/, fn ->
      ExampleDocs.run(root)
    end
  end

  test "a region the example lacks is refused", %{root: root} do
    File.write!(Path.join(root, "docs/guide.md"), block("examples/regions.exs#missing", "x\n"))
    File.write!(Path.join(root, "README.md"), block("examples/whole.exs", @whole))

    assert_raise RuntimeError, ~r/expected one example region missing/, fn ->
      ExampleDocs.run(root)
    end
  end

  test "an example that no guide shows is reported", %{root: root} do
    guides(root)
    File.write!(Path.join(root, "examples/hidden.exs"), "IO.puts(1)\n")
    error = assert_raise RuntimeError, fn -> ExampleDocs.run(root) end
    assert error.message =~ ~s|["examples/hidden.exs"]|
  end

  test "--write repairs the displayed copies and the next check passes", %{root: root} do
    guides(root, "IO.puts(\"stale\")\n", "old\n")
    assert ExampleDocs.run(root, write: true) == 2
    assert File.read!(Path.join(root, "README.md")) =~ "IO.puts(\"whole\")"
    assert ExampleDocs.run(root) == 2
  end

  test "the script prints PASS or exits 1 from the repository root", %{root: root} do
    guides(root)

    assert {"PASS: 2 displayed programs match executable sources\n", 0} =
             System.cmd("elixir", [@script], cd: root)

    guides(root, "stale\n")
    assert {output, 1} = System.cmd("elixir", [@script], cd: root, stderr_to_stdout: true)
    assert output =~ "drifted"
  end
end
