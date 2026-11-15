defmodule LibTmux.Test.TmuxPath do
  @moduledoc false
  # Examples find tmux on PATH. A test names the tmux under test by putting a
  # link called `tmux` first on PATH, and gives the program a TMPDIR of its own
  # so the test can prove the program left nothing behind.

  @doc "The tmux the suite qualifies: LIBTMUX_TMUX, else the one on PATH."
  def executable do
    System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux") ||
      raise "real tmux tests require an explicit tmux binary or tmux on PATH"
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

  Links it into `bin_directory` and puts that first on PATH. TMUX and
  TMUX_PANE are removed and TMPDIR is `tmp_directory`.
  """
  def environment(executable, bin_directory, tmp_directory) do
    File.mkdir_p!(bin_directory)
    link = Path.join(bin_directory, "tmux")
    File.rm(link)
    File.ln_s!(executable, link)

    System.get_env()
    |> Map.drop(["TMUX", "TMUX_PANE"])
    |> Map.put("PATH", bin_directory <> ":" <> System.get_env("PATH", ""))
    |> Map.put("TMPDIR", tmp_directory)
  end
end
