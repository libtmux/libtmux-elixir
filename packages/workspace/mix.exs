defmodule LibTmuxWorkspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :libtmux_workspace,
      version: "0.1.0-dev",
      elixir: ">= 1.20.4 and < 2.0.0",
      description: "Workspace loading and planning for libtmux; under implementation",
      source_url: "https://github.com/libtmux/libtmux-elixir",
      package: [licenses: ["MIT"], files: ["lib", "mix.exs", "README.md", "LICENSE", "assets"]],
      deps: deps()
    ]
  end

  defp deps do
    if System.get_env("LIBTMUX_SOURCE_DEPS") == "1" do
      [{:libtmux, path: "../.."}]
    else
      [{:libtmux, "~> 0.1.0-dev"}]
    end
  end
end
