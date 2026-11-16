defmodule LibTmux.Test.CapabilityClient do
  @moduledoc false
  # Counterfeit CLI replies exercise the public observation decoder. A real
  # owned daemon supplies the live PID; these replies prove no tmux support.

  def build(path, context) do
    escript = System.find_executable("escript") || raise "escript is required"
    {__MODULE__, beam, _file} = :code.get_object_code(__MODULE__)
    elixir_ebin = Path.join(Application.app_dir(:elixir), "ebin")

    :ok =
      :escript.create(String.to_charlist(path), [
        {:shebang, String.to_charlist(escript)},
        {:emu_args, String.to_charlist(" +S 1:1 +SDcpu 1 +SDio 1 -noinput -pa " <> elixir_ebin)},
        {:beam, beam}
      ])

    File.write!(path <> ".json", JSON.encode!(context))
    File.chmod!(path, 0o700)
    path
  end

  def main(arguments) do
    arguments = Enum.map(arguments, &List.to_string/1)
    path = :escript.script_name() |> List.to_string()
    context = JSON.decode!(File.read!(path <> ".json"))
    count = if File.exists?(path <> ".count"), do: File.read!(path <> ".count"), else: "0"
    count = String.to_integer(count) + 1
    File.write!(path <> ".count", Integer.to_string(count))
    index = Enum.find_index(arguments, &(&1 == "-F"))
    true = is_integer(index)
    format = Enum.at(arguments, index + 1)
    mode = context["mode"]

    version =
      cond do
        mode == "unknown" -> "3.8a"
        mode == "changed" and count > 1 -> "3.7"
        true -> "3.8"
      end

    row =
      format
      |> String.replace(~S"#{pid}", if(mode == "invalid-pid", do: "0", else: context["pid"]))
      |> String.replace(~S"#{start_time}", context["started"])
      |> String.replace(~S"#{version}", version)

    if mode == "diagnostic", do: IO.puts(:stderr, "counterfeit diagnostic")
    IO.write(row <> if(mode == "truncated", do: "", else: "\n"))
    if mode == "duplicate", do: IO.puts(row)
  end
end
