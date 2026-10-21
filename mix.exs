Code.require_file("mix_tasks/compile.libtmux_io.ex", __DIR__)

defmodule LibTmux.MixProject do
  use Mix.Project

  @source_url "https://github.com/libtmux/libtmux-elixir"

  def project do
    [
      app: :libtmux,
      version: "0.1.0-dev",
      elixir: ">= 1.20.4 and < 2.0.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/compiler/")],
      compilers: [:libtmux_io | Mix.compilers()],
      description: "Elixir tmux client with explicit observations and operation outcomes",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: [
          "mix.exs",
          "mix_tasks",
          "c_src",
          "lib",
          "README.md",
          "LICENSE",
          ".tool-versions",
          "AGENTS.md",
          ".github/CONTRIBUTING.md",
          ".github/WRITING.md",
          "docs",
          "priv/tmux"
        ]
      ],
      deps: [{:ex_doc, "~> 0.40.4", only: :dev, runtime: false}],
      docs: &docs/0
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp docs do
    source_ref = System.get_env("DOCS_SOURCE_REF", "main")
    blob = @source_url <> "/blob/" <> source_ref <> "/"
    tree = @source_url <> "/tree/" <> source_ref <> "/"

    # ExDoc flattens extras; keep repository-relative links in the originals.
    replacements = %{
      "README.md" => [{".tool-versions", blob <> ".tool-versions"}],
      ".github/CONTRIBUTING.md" => [
        {"../.tool-versions", blob <> ".tool-versions"},
        {"../mix.exs", blob <> "mix.exs"}
      ],
      "AGENTS.md" => [{"mix.exs", blob <> "mix.exs"}],
      "docs/implementation.md" => [
        {"../priv/tmux/support.json", blob <> "priv/tmux/support.json"}
      ],
      "docs/ownership.md" => [{"../c_src/README.md", blob <> "c_src/README.md"}],
      "docs/branding.md" => [
        {"assets/", tree <> "docs/assets/"},
        {"assets/source.json", blob <> "docs/assets/source.json"},
        {"../packages/workspace/assets/", tree <> "packages/workspace/assets/"},
        {"../packages/mcp/assets/", tree <> "packages/mcp/assets/"}
      ]
    }

    extras = [
      "README.md",
      "docs/observations.md",
      "docs/filtering.md",
      "docs/schema.md",
      "docs/ownership.md",
      "docs/encoding.md",
      "docs/design.md",
      "docs/implementation.md",
      "docs/branding.md",
      "AGENTS.md",
      ".github/CONTRIBUTING.md",
      ".github/WRITING.md",
      "LICENSE"
    ]

    extras =
      Enum.map(extras, fn source ->
        case replacements[source] do
          nil ->
            source

          links ->
            text =
              Enum.reduce(links, File.read!(source), fn {from, to}, text ->
                String.replace(text, "(" <> from <> ")", "(" <> to <> ")")
              end)

            path = Path.join([Mix.Project.build_path(), "doc_sources", source])
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, text)
            {path, source: source}
        end
      end)

    [
      main: "readme",
      source_ref: source_ref,
      logo: "docs/assets/logo.svg",
      assets: %{"docs/assets" => "docs/assets"},
      extras: extras
    ]
  end
end
