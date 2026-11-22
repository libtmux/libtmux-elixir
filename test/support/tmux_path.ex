defmodule LibTmux.Test.TmuxPath do
  @moduledoc false
  # Examples find tmux on PATH. A test names the tmux under test by putting a
  # link called `tmux` first on PATH, and gives the program a TMPDIR of its own
  # so the test can prove the program left nothing behind.

  alias LibTmux.Test.SandboxGuard

  @doc """
  The tmux the suite qualifies: `LIBTMUX_TEST_TMUX`, else `LIBTMUX_TMUX`, else
  the one on `PATH`.
  """
  def executable(env \\ System.get_env(), find_executable \\ &System.find_executable/1) do
    non_blank(env["LIBTMUX_TEST_TMUX"]) ||
      non_blank(env["LIBTMUX_TMUX"]) ||
      find_executable.("tmux") ||
      raise "real tmux tests require an explicit tmux binary or tmux on PATH"
  end

  @doc "Removes inherited tmux and `LIBTMUX_SOCKET*` selectors from `env`."
  def clean_env(env \\ System.get_env()) do
    Map.drop(env, SandboxGuard.inherited(env))
  end

  @doc "A private directory under `parent`, mode 700, named for the caller."
  def private_directory(parent, name) do
    path = Path.join(parent, "#{name}-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  @doc """
  The environment for a program that must find `executable` as `tmux`.

  Links it into `bin_directory` and puts that first on PATH. Inherited tmux and
  `LIBTMUX_SOCKET*` selectors are removed and TMPDIR is `tmp_directory`.
  """
  def environment(executable, bin_directory, tmp_directory, env \\ System.get_env()) do
    File.mkdir_p!(bin_directory)
    link = Path.join(bin_directory, "tmux")
    File.rm(link)
    File.ln_s!(executable, link)

    env
    |> clean_env()
    |> Map.put("PATH", bin_directory <> ":" <> Map.get(env, "PATH", ""))
    |> Map.put("TMPDIR", tmp_directory)
  end

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_blank(_value), do: nil
end
