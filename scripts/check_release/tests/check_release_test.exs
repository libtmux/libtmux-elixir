# Run with: elixir scripts/check_release/tests/check_release_test.exs
#
# Proves the release check refuses a package that has lost its changelog. Each
# rule has a deliberate break on a copy of the real tree: the file deleted, its
# Unreleased section dropped, another package's name written over its own, or
# its `files` entry removed. The check has to report that break and name the
# file. A tree that is not broken has to pass, or the breaks prove nothing.

ExUnit.start()

defmodule CheckReleaseTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @script Path.expand("../check_release.exs", __DIR__)
  @version ~r/version: "([^"]+)"/
           |> Regex.run(File.read!(Path.join(@root, "mix.exs")))
           |> List.last()

  setup do
    tree =
      Path.join(
        System.tmp_dir!(),
        "ltx-release-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)

    # What the release check reads: the Mix project and its changelog.
    File.cp_r!(Path.join(@root, "mix_tasks"), Path.join(tree, "mix_tasks"))

    for name <- ["mix.exs", "CHANGELOG.md"],
        do: File.cp!(Path.join(@root, name), Path.join(tree, name))

    {:ok, tree: tree}
  end

  defp release_check(tree) do
    System.cmd("elixir", [@script, "v" <> @version], cd: tree, stderr_to_stdout: true)
  end

  defp edit(tree, name, fun) do
    path = Path.join(tree, name)
    File.write!(path, path |> File.read!() |> fun.())
  end

  defp refused(tree, fragment) do
    {output, status} = release_check(tree)
    assert status != 0, output
    assert output =~ fragment
  end

  defp passes(tree) do
    {output, status} = release_check(tree)
    assert status == 0, output
  end

  test "the tree passes", %{tree: tree} do
    {output, 0} = release_check(tree)
    assert JSON.decode!(String.trim(output)) == %{"package" => "libtmux", "version" => @version}
  end

  test "a missing changelog is refused", %{tree: tree} do
    File.rm!(Path.join(tree, "CHANGELOG.md"))
    refused(tree, "CHANGELOG.md: libtmux has no changelog")
  end

  test "a missing changelog is reported once", %{tree: tree} do
    File.rm!(Path.join(tree, "CHANGELOG.md"))
    {output, status} = release_check(tree)
    assert status != 0
    refute output =~ "does not include"
  end

  test "a missing Unreleased section is refused", %{tree: tree} do
    edit(tree, "CHANGELOG.md", &String.replace(&1, "## Unreleased\n", ""))
    refused(tree, ~s|CHANGELOG.md: has no "## Unreleased" section|)
  end

  test "an Unreleased heading inside a fence does not count", %{tree: tree} do
    edit(
      tree,
      "CHANGELOG.md",
      &String.replace(&1, "## Unreleased\n", "```markdown\n## Unreleased\n```\n")
    )

    refused(tree, ~s|CHANGELOG.md: has no "## Unreleased" section|)
  end

  test "a tilde fence or a longer fence still holds the heading", %{tree: tree} do
    original = File.read!(Path.join(tree, "CHANGELOG.md"))

    # A longer fence is not closed by a shorter line inside it; a tilde fence
    # holds the heading with nothing else to hide it.
    for {fence, inner} <- [{"~~~", ""}, {"````", "```\n"}] do
      File.write!(
        Path.join(tree, "CHANGELOG.md"),
        String.replace(
          original,
          "## Unreleased\n",
          "#{fence}markdown\n#{inner}## Unreleased\n#{fence}\n"
        )
      )

      refused(tree, ~s|CHANGELOG.md: has no "## Unreleased" section|)
    end
  end

  test "a closing fence with an info string does not close", %{tree: tree} do
    edit(
      tree,
      "CHANGELOG.md",
      &String.replace(&1, "## Unreleased\n", "```markdown\n```js\n## Unreleased\n```\n")
    )

    refused(tree, ~s|CHANGELOG.md: has no "## Unreleased" section|)
  end

  test "another package's name over the opening sentence is refused", %{tree: tree} do
    edit(
      tree,
      "CHANGELOG.md",
      &String.replace(&1, "Notable changes to `libtmux`.", "Notable changes to `another`.")
    )

    refused(tree, "CHANGELOG.md: is the changelog of another, not libtmux")
  end

  test "an opening sentence that is not at the top is refused", %{tree: tree} do
    edit(
      tree,
      "CHANGELOG.md",
      &String.replace(&1, "# Changelog\n\n", "# Changelog\n\nSomething else first.\n\n")
    )

    refused(tree, ~s|CHANGELOG.md: does not open with "Notable changes to `libtmux`."|)
  end

  test "a changelog without the opening sentence is refused", %{tree: tree} do
    edit(tree, "CHANGELOG.md", &Regex.replace(~r/Notable changes to `[^`]+`\.\n\n/, &1, ""))
    refused(tree, ~s|CHANGELOG.md: does not open with "Notable changes to `libtmux`."|)
  end

  test "a files pattern that matches the changelog ships it", %{tree: tree} do
    edit(tree, "mix.exs", &String.replace(&1, ~s|"CHANGELOG.md"|, ~s|"CHANGELOG*"|))
    passes(tree)
  end

  test "an omitted files list is Hex's default", %{tree: tree} do
    edit(tree, "mix.exs", &Regex.replace(~r/,\s*files: \[[^\]]*\]/, &1, ""))
    refute File.read!(Path.join(tree, "mix.exs")) =~ "files:"
    passes(tree)
  end

  test "a nested changelog is not the package's changelog", %{tree: tree} do
    File.mkdir!(Path.join(tree, "docs"))
    File.write!(Path.join(tree, "docs/CHANGELOG.md"), "nested\n")
    edit(tree, "mix.exs", &String.replace(&1, ~s|"CHANGELOG.md"|, ~s|"docs/CHANGELOG.md"|))
    refused(tree, "mix.exs: `files` does not include CHANGELOG.md")
  end

  test "a manifest that does not ship the changelog is refused", %{tree: tree} do
    edit(tree, "mix.exs", &String.replace(&1, ~s|"CHANGELOG.md",|, ""))
    refused(tree, "mix.exs: `files` does not include CHANGELOG.md")
  end

  test "a tag that does not match the version is refused", %{tree: tree} do
    {output, status} = System.cmd("elixir", [@script, "v9.9.9"], cd: tree, stderr_to_stdout: true)
    assert status != 0
    assert output =~ "release tag must match v#{@version}"
  end
end
