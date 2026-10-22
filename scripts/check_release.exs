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

if output = System.get_env("GITHUB_OUTPUT") do
  File.write!(output, "version=#{version}\n", [:append])
end

IO.puts(JSON.encode!(%{package: "libtmux", version: version}))
