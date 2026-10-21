defmodule LibTmuxMCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :libtmux_mcp,
      version: "0.1.0-dev",
      elixir: ">= 1.20.4 and < 2.0.0",
      description: "MCP STDIO adapter for libtmux; under implementation",
      source_url: "https://github.com/libtmux/libtmux-elixir",
      package: [licenses: ["MIT"], files: ["lib", "mix.exs", "README.md", "LICENSE", "assets"]],
      deps: deps()
    ]
  end

  defp deps do
    if System.get_env("LIBTMUX_SOURCE_DEPS") == "1" do
      [{:libtmux, path: "../.."}, {:libtmux_workspace, path: "../workspace"}]
    else
      [{:libtmux, "~> 0.1.0-dev"}, {:libtmux_workspace, "~> 0.1.0-dev"}]
    end
  end
end
