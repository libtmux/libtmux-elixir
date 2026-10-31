defmodule LibTmux.Test.SandboxGuard do
  @moduledoc false
  # Keeps a test run away from the tmux server of whoever runs it. A Server
  # with no socket reaches the server tmux would pick, so the suite must not
  # inherit TMUX, TMUX_PANE or a LIBTMUX_SOCKET variable, and any bare tmux it
  # starts must land in a directory of its own. Messages name variables and
  # checks and never repeat a value.

  @cleared ["TMUX", "TMUX_PANE"]
  @variable_prefix "LIBTMUX_SOCKET"
  @path_limit 100
  # tmux binds TMUX_TMPDIR/tmux-UID/default, and a UID has at most ten digits.
  @suffix_bytes byte_size("/tmux-4294967295/default")

  @doc "Names the variables of `env` that a run must not inherit."
  def inherited(env) do
    env
    |> Map.keys()
    |> Enum.filter(&(&1 in @cleared or String.starts_with?(&1, @variable_prefix)))
    |> Enum.sort()
  end

  @doc "Lists why `env` and the `TMUX_TMPDIR` directory `dir` are not a sandbox; empty when they are."
  def verify(env, dir) do
    Enum.map(inherited(env), &"#{&1} is set") ++
      if(env["TMUX_TMPDIR"] == dir, do: [], else: ["TMUX_TMPDIR is not the sandbox directory"]) ++
      problems(dir)
  end

  @doc "Lists why `dir` cannot be a private `TMUX_TMPDIR`; empty when it can."
  def problems(dir) do
    cond do
      not (is_binary(dir) and Path.type(dir) == :absolute) ->
        ["TMUX_TMPDIR is not an absolute path"]

      byte_size(dir) + @suffix_bytes > @path_limit ->
        ["a socket under TMUX_TMPDIR would exceed #{@path_limit} bytes"]

      true ->
        case File.stat(dir) do
          {:ok, %File.Stat{type: :directory, mode: mode}} ->
            if Bitwise.band(mode, 0o777) == 0o700, do: [], else: ["TMUX_TMPDIR is not owner-only"]

          {:ok, _stat} ->
            ["TMUX_TMPDIR is not a directory"]

          {:error, _reason} ->
            ["TMUX_TMPDIR does not exist"]
        end
    end
  end

  @doc "Removes the inherited variables, points `TMUX_TMPDIR` at a fresh private directory and returns it; halts when it cannot."
  def enter! do
    Enum.each(inherited(System.get_env()), &System.delete_env/1)

    case create() do
      {:ok, dir} ->
        System.put_env("TMUX_TMPDIR", dir)

        case verify(System.get_env(), dir) do
          [] ->
            dir

          problems ->
            File.rm_rf(dir)
            refuse!(problems)
        end

      {:error, problems} ->
        refuse!(problems)
    end
  end

  @doc "Lists the sockets under `dir`, relative to it. tmux leaves its socket file behind when a server exits."
  def sockets(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&match?({:ok, %File.Stat{type: :other}}, File.stat(&1)))
    |> Enum.sort()
  end

  @doc "Lists the sockets under `dir`, relative to it, that a server still answers on."
  def live(dir) do
    for path <- sockets(dir), answering?(path), do: Path.relative_to(path, dir)
  end

  @doc "Whether a server accepts a connection on the socket at `path`."
  def answering?(path) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:local, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc "Removes `dir`, or halts and keeps it when a server still answers in it."
  def leave!(dir) do
    case live(dir) do
      [] ->
        File.rm_rf!(dir)

      answering ->
        IO.puts(
          :stderr,
          "tmux sandbox kept, servers still answer: " <> Enum.join(answering, ", ")
        )

        System.halt(1)
    end
  end

  defp create do
    name = "ltx-#{System.pid()}-#{System.unique_integer([:positive])}"

    dir =
      Enum.find_value(Enum.uniq([System.tmp_dir!(), "/tmp"]), fn base ->
        candidate = Path.join(base, name)
        if byte_size(candidate) + @suffix_bytes <= @path_limit, do: candidate
      end)

    with {:ok, dir} <- if(dir, do: {:ok, dir}, else: {:error, :too_long}),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, ["TMUX_TMPDIR could not be created (#{reason})"]}
    end
  end

  defp refuse!(problems) do
    IO.puts(:stderr, "tmux sandbox refused to run the suite: " <> Enum.join(problems, "; "))
    System.halt(1)
  end
end
