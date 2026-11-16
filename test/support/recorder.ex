defmodule LibTmux.Test.Recorder do
  @moduledoc false
  # Stands in for tmux where a test checks what a Server sends. Argv goes to
  # stdout, one argument per line. Stderr names which tmux variables arrived and
  # never their values. `build/1` writes it as an escript, so it starts from an
  # empty environment, with no PATH or locale.

  @doc "Writes the recorder to `path` as an executable escript."
  def build(path) do
    escript = System.find_executable("escript") || raise "escript is not on PATH"
    {__MODULE__, beam, _file} = :code.get_object_code(__MODULE__)
    elixir_ebin = Path.join(Application.app_dir(:elixir), "ebin")

    :ok =
      :escript.create(String.to_charlist(path), [
        {:shebang, String.to_charlist(escript)},
        {:emu_args, String.to_charlist(" -noinput -pa " <> elixir_ebin)},
        {:beam, beam}
      ])

    File.chmod!(path, 0o755)
    path
  end

  @doc false
  def main(arguments) do
    Enum.each(arguments, &IO.puts/1)

    for name <- ["TMUX", "TMUX_PANE"] do
      state = if System.fetch_env(name) == :error, do: "unset", else: "set"
      IO.puts(:stderr, "#{name}=#{state}")
    end
  end
end
