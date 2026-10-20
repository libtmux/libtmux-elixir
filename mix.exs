defmodule LibTmux.MixProject do
  use Mix.Project

  @source_url "https://github.com/libtmux/libtmux-elixir"

  def project do
    [
      app: :libtmux,
      version: "0.1.0-dev",
      elixir: ">= 1.20.4 and < 2.0.0",
      description: "Elixir tmux client: unpublished repository scaffold",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: [
          "mix.exs",
          "README.md",
          "LICENSE",
          ".tool-versions",
          "AGENTS.md",
          ".github/CONTRIBUTING.md",
          ".github/WRITING.md",
          "docs",
          "priv"
        ]
      ],
      deps: []
    ]
  end
end
