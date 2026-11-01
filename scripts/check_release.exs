Mix.start()
Code.require_file("mix.exs")

config = Mix.Project.config()
package = Keyword.get(config, :package, [])

unless config[:app] == :libtmux and
         to_string(Keyword.get(package, :name, :libtmux)) == "libtmux" and
         is_nil(package[:organization]),
       do: Mix.raise("release must target the public libtmux core package")

version = Keyword.fetch!(config, :version)

parsed =
  case Version.parse(version) do
    {:ok, parsed} -> parsed
    :error -> Mix.raise("release version must follow SemVer")
  end

if "dev" in parsed.pre, do: Mix.raise("development versions cannot be published")

unless System.argv() == ["v" <> version],
  do: Mix.raise("release tag must match v#{version}")

# Every package keeps its own changelog and ships it, so a release does not go
# out while a sibling package has lost its file. For the core and each project
# under packages/, the changelog must exist, open with "Notable changes to" and
# the package's own name, hold an `## Unreleased` heading outside any code
# fence, and be matched by the `files` list that puts it in the Hex archive.
heading? = fn markdown, heading ->
  markdown
  |> String.split("\n")
  |> Enum.reduce({nil, false}, fn line, {fence, found} ->
    case {fence, Regex.run(~r/^\s*(`{3,}|~{3,})(.*)$/, line)} do
      {nil, [_, marker, _info]} ->
        {marker, found}

      {nil, nil} ->
        {nil, found or line == heading}

      {open, [_, marker, rest]} ->
        # A closing fence uses the opening character, is at least as long, and
        # carries no info string.
        closes? =
          String.first(marker) == String.first(open) and
            String.length(marker) >= String.length(open) and String.trim(rest) == ""

        {if(closes?, do: nil, else: open), found}

      {open, nil} ->
        {open, found}
    end
  end)
  |> elem(1)
end

# An omitted `files` list falls back to Hex's default, which includes CHANGELOG*.
# Otherwise some entry must expand to the changelog at the package root.
ships? = fn directory, package ->
  changelog = Path.expand(Path.join(directory, "CHANGELOG.md"))

  case Keyword.fetch(package, :files) do
    :error ->
      true

    {:ok, files} ->
      Enum.any?(files, fn pattern ->
        directory
        |> Path.join(pattern)
        |> Path.wildcard()
        |> Enum.any?(&(Path.expand(&1) == changelog))
      end)
  end
end

packages =
  [{".", config[:app], package}] ++
    for mix_file <- Path.wildcard("packages/*/mix.exs") |> Enum.sort() do
      directory = Path.dirname(mix_file)

      Mix.Project.in_project(
        String.to_atom("release_check_" <> Path.basename(directory)),
        directory,
        fn _module ->
          project = Mix.Project.config()
          {directory, project[:app], Keyword.get(project, :package, [])}
        end
      )
    end

changelog_failures =
  Enum.flat_map(packages, fn {directory, app, package} ->
    name = to_string(Keyword.get(package, :name, app))
    path = Path.join(directory, "CHANGELOG.md") |> Path.relative_to(".")

    # A file that is missing is reported once, below, not again as a manifest
    # that fails to ship it.
    ships =
      if not File.exists?(path) or ships?.(directory, package),
        do: [],
        else: [
          "#{Path.join(directory, "mix.exs") |> Path.relative_to(".")}: `files` does not include CHANGELOG.md"
        ]

    problems =
      case File.read(path) do
        {:error, _} ->
          ["#{path}: #{name} has no changelog"]

        {:ok, changelog} ->
          opening =
            case Regex.run(~r/\A# Changelog\n+Notable changes to `([^`]+)`\.$/m, changelog) do
              [_, ^name] -> []
              [_, other] -> ["#{path}: is the changelog of #{other}, not #{name}"]
              nil -> ["#{path}: does not open with \"Notable changes to `#{name}`.\""]
            end

          unreleased =
            if heading?.(changelog, "## Unreleased"),
              do: [],
              else: ["#{path}: has no \"## Unreleased\" section"]

          opening ++ unreleased
      end

    ships ++ problems
  end)

if changelog_failures != [],
  do: Mix.raise("every package needs a changelog:\n" <> Enum.join(changelog_failures, "\n"))

if output = System.get_env("GITHUB_OUTPUT") do
  File.write!(output, "version=#{version}\n", [:append])
end

IO.puts(JSON.encode!(%{package: "libtmux", version: version}))
