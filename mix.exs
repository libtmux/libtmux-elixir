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
      deps: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
