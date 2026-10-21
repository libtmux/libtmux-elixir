[profile] = System.argv()
unless profile in ["reference", "tracking"], do: raise("expected reference or tracking")

support = File.read!("priv/tmux/support.json") |> JSON.decode!()
major = :erlang.system_info(:otp_release) |> List.to_string()
otp = Path.join([List.to_string(:code.root_dir()), "releases", major, "OTP_VERSION"])
otp = otp |> File.read!() |> String.trim()
elixir = System.version()
compiled_otp = System.build_info().otp_release

unless major == support["otp"]["line"] and compiled_otp == major,
  do: raise("Elixir must be compiled for the supported runtime OTP major")

otp_parts = fn value ->
  unless Regex.match?(~r/\A\d+(?:\.\d+)*\z/, value), do: raise("expected a stable OTP version")
  String.split(value, ".") |> Enum.map(&String.to_integer/1)
end

actual = otp_parts.(otp)
minimum = otp_parts.(support["otp"]["minimum"])
width = max(length(actual), length(minimum))
actual = actual ++ List.duplicate(0, width - length(actual))
minimum = minimum ++ List.duplicate(0, width - length(minimum))

unless actual >= minimum and Version.compare(elixir, support["elixir"]["minimum"]) != :lt and
         Version.parse!(elixir).pre == [],
       do: raise("runtime is older than the supported minimum or is a prerelease")

if profile == "reference" do
  unless otp == support["reference"]["otp"] and elixir == support["reference"]["elixir"],
    do: raise("runtime differs from the exact reference pair")
else
  ranges =
    File.stream!(".tool-versions")
    |> Enum.map(&String.split/1)
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [tool, range] -> {tool, range} end)

  for {tool, value} <- [{"erlang", otp}, {"elixir", elixir}] do
    prefix = Map.fetch!(ranges, tool)

    unless value == prefix or String.starts_with?(value, prefix <> "."),
      do: raise("#{tool} does not match its .tool-versions selector")
  end
end

IO.puts(JSON.encode!(%{profile: profile, elixir: elixir, otp: otp, compiled_otp: compiled_otp}))
