# Run with: elixir scripts/ci_plan/tests/ci_docs_test.exs
#
# The README states the tmux floor; the implementation notes and the
# contributor guide state the support table. Each must agree with the manifest,
# and a document that drifts has to be reported.

Code.require_file("../ci_plan.exs", __DIR__)
ExUnit.start()

defmodule CiDocsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @manifest CiPlan.load()

  defp read(path), do: File.read!(Path.join(@root, path))
  defp flat(text), do: text |> String.split() |> Enum.join(" ")

  defp joined(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  # Names each way a document disagrees with the manifest.
  defp problems(manifest, readme, implementation, contributing) do
    names = Enum.map(manifest["required_linux"], & &1["tmux"])
    edges = Enum.uniq([hd(names), List.last(names)])

    {readme, implementation, contributing} =
      {flat(readme), flat(implementation), flat(contributing)}

    for {false, message} <- [
          {String.contains?(implementation, "Required Linux cells are tmux #{joined(names)} on"),
           "the implementation notes do not list the manifest's tmux cells"},
          {String.contains?(implementation, "run the oldest and newest, #{joined(edges)},"),
           "the implementation notes do not name the edges a push runs"},
          {String.contains?(
             contributing,
             "oldest and newest listed tmux release (#{joined(edges)})"
           ), "the contributor guide does not name the edges a push plans"},
          {String.contains?(readme, "tmux #{manifest["tmux_minimum"]} or newer"),
           "the README does not state the manifest's tmux minimum"}
        ],
        do: message
  end

  defp documents,
    do: {read("README.md"), read("docs/implementation.md"), read(".github/CONTRIBUTING.md")}

  test "the documents agree with the manifest" do
    {readme, implementation, contributing} = documents()
    assert problems(@manifest, readme, implementation, contributing) == []
  end

  test "a new release fails until the documents move" do
    {readme, implementation, contributing} = documents()

    manifest = %{
      @manifest
      | "required_linux" => @manifest["required_linux"] ++ [%{"tmux" => "3.9"}]
    }

    assert length(problems(manifest, readme, implementation, contributing)) == 3
  end

  test "a document that drifts is reported" do
    {readme, implementation, contributing} = documents()

    cases = [
      {:readme, String.replace(flat(readme), "tmux 3.3 or newer", "tmux 3.3a or newer"),
       "README does not state the manifest's tmux minimum"},
      {:implementation,
       String.replace(flat(implementation), "3.3, 3.3a, 3.4 and 3.8 on", "3.3 and 3.8 on"),
       "implementation notes do not list"},
      {:implementation,
       String.replace(
         flat(implementation),
         "3.3 and 3.8, and a release",
         "3.3 and 3.4, and a release"
       ), "implementation notes do not name the edges"},
      {:contributing, String.replace(flat(contributing), "(3.3 and 3.8)", "(3.3a and 3.8)"),
       "contributor guide does not name the edges"}
    ]

    originals = %{
      readme: flat(readme),
      implementation: flat(implementation),
      contributing: flat(contributing)
    }

    for {name, text, message} <- cases do
      assert text != originals[name], message
      changed = Map.put(originals, name, text)
      reported = problems(@manifest, changed.readme, changed.implementation, changed.contributing)
      assert Enum.any?(reported, &String.contains?(&1, message)), inspect({message, reported})
    end
  end
end
