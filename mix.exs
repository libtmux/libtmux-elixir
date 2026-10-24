Code.require_file("mix_tasks/compile.libtmux_io.ex", __DIR__)

defmodule LibTmux.MixProject do
  use Mix.Project

  @source_url "https://github.com/libtmux/libtmux-elixir"

  def project do
    [
      app: :libtmux,
      version: "0.0.1-alpha.3",
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
          "examples",
          "README.md",
          "CHANGELOG.md",
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
      "README.md" => [{"examples/readme.exs", blob <> "examples/readme.exs"}],
      ".github/CONTRIBUTING.md" => [
        {"../.tool-versions", blob <> ".tool-versions"},
        {"../mix.exs", blob <> "mix.exs"}
      ],
      "AGENTS.md" => [{"mix.exs", blob <> "mix.exs"}],
      "docs/implementation.md" => [
        {"../priv/tmux/support.json", blob <> "priv/tmux/support.json"}
      ],
      "docs/advanced-execution.md" => [
        {"../examples/capture_and_read.exs", blob <> "examples/capture_and_read.exs"}
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
      "CHANGELOG.md",
      "docs/first-task.md",
      "docs/standalone-demo.md",
      "docs/one-shot-actions.md",
      "docs/managed-control.md",
      "docs/recovery.md",
      "docs/owned-server.md",
      "docs/advanced-execution.md",
      "docs/mental-model.md",
      "docs/observations.md",
      "docs/filtering.md",
      "docs/api-examples.md",
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
      groups_for_extras: [
        Tasks:
          ~r/(first-task|standalone-demo|one-shot-actions|managed-control|recovery|owned-server|advanced-execution)/,
        "Concepts and reference": ~r/(mental-model|observations|filtering|schema|api-examples)/,
        "Design and internals": ~r/(ownership|encoding|design|implementation)/,
        Contributing: ~r/(AGENTS|CONTRIBUTING|WRITING|branding|LICENSE)/
      ],
      groups_for_modules: [
        "Observe and select": [
          LibTmux.Server,
          LibTmux.Snapshot,
          LibTmux.Selection,
          LibTmux.Filter,
          LibTmux.Session,
          LibTmux.Window,
          LibTmux.WindowLink,
          LibTmux.Pane,
          LibTmux.Client
        ],
        Execute: [
          LibTmux.Action,
          LibTmux.Action.CompletionError,
          LibTmux.Control,
          LibTmux.Control.Request,
          LibTmux.Operation,
          LibTmux.Control.ExecutionError,
          LibTmux.Control.ScopeFailure
        ],
        "Contracts and encoding": [
          LibTmux.Ref,
          LibTmux.Error,
          LibTmux.Deadline,
          LibTmux.Command,
          LibTmux.Format,
          LibTmux.Codec,
          LibTmux.Protocol,
          LibTmux.Schema,
          LibTmux.Wire,
          LibTmux.Transport.OneShot
        ]
      ],
      extras: extras
    ]
  end
end
