defmodule LibTmux.QuickstartExampleIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag reason: "Runs the quickstart against a private tmux server"
  @moduletag timeout: 180_000

  @root Path.expand("..", __DIR__)
  @stop_script Path.join(@root, "test/support/quickstart_stop.py")
  @kept_environment ~w(PATH HOME ERL_FLAGS MIX_HOME HEX_HOME CC)
  # What the wrapper prints when it sees kill-server; the example must hide it.
  @noise "noise on kill-server"

  setup_all do
    tmux = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    tmux || raise "the quickstart test requires a tmux executable"

    base = private_directory(System.tmp_dir!(), "lqx-#{System.pid()}")
    on_exit(fn -> File.rm_rf!(base) end)

    # Only the dependency changes: the published pin becomes this checkout.
    published = ~s|Mix.install([{:libtmux, "~> 0.1"}])|
    core = System.get_env("LIBTMUX_QUICKSTART_PACKAGE", @root)
    installed = ~s|Mix.install([{:libtmux, path: #{inspect(core)}}])|
    source = File.read!(Path.join(core, "examples/quickstart.exs"))
    assert String.starts_with?(source, published <> "\n")
    program = Path.join(base, "quickstart.exs")
    body = String.replace_prefix(source, published, "")
    File.write!(program, installed <> body)

    context = %{
      base: base,
      tmux: tmux,
      program: program,
      install: Path.join(base, "install")
    }

    # Compile once, so the asserted runs print only the program's output.
    warmed = run(context, base, ["-e", installed], base)
    assert warmed.exit_status == 0, warmed.stdout <> warmed.stderr
    assert warmed.stderr == ""
    context
  end

  setup context do
    tmp = private_directory(context.base, "t")
    on_exit(fn -> stop_servers(context.tmux, tmp) end)
    {:ok, tmp: tmp, prefix: Path.join(tmp, "libtmux-")}
  end

  test "prints the topology from a private directory", context do
    result = run_example(context)

    assert result.exit_status == 0, result.stdout <> result.stderr
    assert result.stdout == "demo: 2 windows, 3 panes\n"
    assert result.stderr == ""
    assert [record] = records(context)
    assert_private(context, record)
    assert Path.wildcard(context.prefix <> "*") == []
    assert [] == listeners(context.prefix)
    assert_retired(context, [3])
  end

  test "names the directory of each run differently", context do
    for _run <- 1..2 do
      result = run_example(context)
      assert result.exit_status == 0, result.stdout <> result.stderr
      assert result.stdout == "demo: 2 windows, 3 panes\n"
    end

    assert [first, second] = records(context)
    assert_private(context, first)
    assert_private(context, second)
    refute Path.dirname(Enum.at(first, 1)) == Path.dirname(Enum.at(second, 1))
    assert Path.wildcard(context.prefix <> "*") == []
    assert_retired(context, [3, 3])
  end

  test "keeps a leftover directory from an earlier run", context do
    leftover = context.prefix <> "12345"
    File.mkdir!(leftover)

    result = run_example(context)

    assert result.exit_status == 0, result.stdout <> result.stderr
    assert result.stdout == "demo: 2 windows, 3 panes\n"
    assert Path.wildcard(context.prefix <> "*") == [leftover]
    assert_retired(context, [3])
  end

  test "a refused command stops the server and removes the directory", c do
    result = run_example(c, "new-window")

    assert result.exit_status == 1
    assert result.stdout == ""
    assert result.stderr =~ "** (MatchError)"
    assert result.stderr =~ "refused new-window"
    refute result.stderr =~ @noise
    assert [record] = records(c)
    assert_private(c, record)
    assert Path.wildcard(c.prefix <> "*") == []
    assert [] == listeners(c.prefix)
    assert_retired(c, [2])
  end

  test "a tmux that cannot start a server leaves no directory", context do
    stub = Path.join(context.tmp, "stub")
    File.mkdir!(stub)
    File.write!(Path.join(stub, "tmux"), "#!/bin/sh\nexit 3\n")
    File.chmod!(Path.join(stub, "tmux"), 0o755)

    result = run(context, context.tmp, [context.program], stub)

    assert result.exit_status == 1
    assert result.stdout == ""
    assert result.stderr =~ "** (MatchError)"
    assert result.stderr =~ ~s|{"", 3}|
    assert Path.wildcard(context.prefix <> "*") == []
  end

  test "the listener probe sees a live server and then its exit", context do
    socket = context.prefix <> "control.sock"
    assert [] == listeners(context.prefix)

    create = ["-S", socket, "-f", "/dev/null", "new-session", "-d", "/bin/cat", "--"]
    clean = [{"TMUX", nil}, {"TMUX_PANE", nil}]
    {_, 0} = System.cmd(context.tmux, create, env: clean)
    assert [_ | _] = listeners(context.prefix)

    {pids, 0} =
      System.cmd(context.tmux, ["-S", socket, "display-message", "-p", "\#{pid} \#{pane_pid}"],
        env: clean
      )

    watch =
      pids
      |> String.split()
      |> Enum.map(&String.to_integer/1)
      |> LibTmux.Test.OwnedTmux.watch_processes()

    {_, 0} = System.cmd(context.tmux, ["-S", socket, "kill-server"])
    :ok = LibTmux.Test.OwnedTmux.await_exit(watch)
    assert [] == listeners(context.prefix)
  end

  defp assert_retired(context, pane_counts) do
    records =
      context.tmp
      |> Path.join("retired")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert records ==
             Enum.map(pane_counts, &%{"server_exited" => true, "panes_exited" => &1})
  end

  defp records(context) do
    context.tmp
    |> Path.join("record")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, " ", parts: 2))
  end

  # The directory is private to the run: mode 700 and inside the test's TMPDIR.
  defp assert_private(context, [mode, socket]) do
    parent = Regex.escape(context.tmp)
    assert mode == "700"
    assert socket =~ ~r|\A#{parent}/libtmux-[0-9a-f]{16}/tmux\.sock\z|
  end

  # Runs the example through a tmux that appends the socket directory's mode
  # and the socket path to a record at each new-session, prints noise on
  # kill-server, refuses the `refused` command if given, and otherwise execs
  # the real binary.
  defp run_example(context, refused \\ nil) do
    wrapper = Path.join(context.tmp, "wrapper")
    File.mkdir_p!(wrapper)
    record = Path.join(context.tmp, "record")
    refusal = refused && "#{refused}) echo 'refused #{refused}' >&2; exit 4 ;;"

    File.write!(Path.join(wrapper, "tmux"), """
    #!/bin/sh
    previous=
    for argument in "$@"; do
      [ "$previous" = -S ] && socket=$argument
      previous=$argument
      case $argument in
        new-session)
          echo "$(stat -c %a "${socket%/*}") $socket" >> '#{record}' ;;
        kill-server)
          echo '#{@noise}' >&2
          exec python3 '#{@stop_script}' '#{context.tmux}' \\
            '#{Path.join(context.tmp, "retired")}' "$socket" "$@" ;;
        #{refusal}
      esac
    done
    exec '#{context.tmux}' "$@"
    """)

    File.chmod!(Path.join(wrapper, "tmux"), 0o755)
    run(context, context.tmp, [context.program], wrapper)
  end

  # A plain child process, not OneShot: OneShot retires every descendant on
  # exit, which would hide a server the example forgot to stop.
  defp run(context, directory, arguments, path_head) do
    stderr = Path.join(directory, "stderr.txt")
    elixir = System.find_executable("elixir")
    # The umask lets a missing chmod leave a world-readable directory.
    script = ~S|umask 022; exec timeout --kill-after=5 120 "$@" 2>"$0"|

    environment =
      System.get_env()
      |> Map.take(@kept_environment)
      |> Map.merge(%{
        "PATH" => path_head <> ":" <> System.get_env("PATH", ""),
        "TMPDIR" => directory,
        "MIX_INSTALL_DIR" => context.install,
        "HEX_OFFLINE" => "1",
        "LC_ALL" => "C.UTF-8",
        "SHELL" => "/bin/sh",
        "ENV" => "/dev/null",
        "BASH_ENV" => "/dev/null"
      })
      |> Enum.map(fn {name, value} -> name <> "=" <> value end)

    command =
      ["-i" | environment] ++
        ["/bin/sh", "-c", script, stderr, elixir | arguments]

    env = System.find_executable("env")
    {stdout, status} = System.cmd(env, command, cd: directory)
    %{stdout: stdout, stderr: File.read!(stderr), exit_status: status}
  end

  defp private_directory(parent, name) do
    path = Path.join(parent, "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  # A failed run may leave a server. Find it by its socket, never by name: by
  # path while the file exists, else by the listening socket's identity.
  defp stop_servers(tmux, tmp) do
    sockets =
      Path.wildcard(Path.join(tmp, "libtmux-*/tmux.sock")) ++
        Path.wildcard(Path.join(tmp, "libtmux-*.sock"))

    for socket <- sockets do
      System.cmd(tmux, ["-S", socket, "kill-server"], stderr_to_stdout: true)
    end

    for {inode, _path} <- listeners(tmp), pid <- holders(inode) do
      System.cmd("kill", [pid])
    end

    File.rm_rf!(tmp)
  end

  defp listeners(prefix) do
    "/proc/net/unix"
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_, _, _, _, _, _, inode, path] ->
          if String.contains?(path, prefix), do: [{inode, path}], else: []

        _other ->
          []
      end
    end)
  end

  defp holders(inode) do
    for descriptors <- Path.wildcard("/proc/[0-9]*/fd/*"),
        File.read_link(descriptors) == {:ok, "socket:[#{inode}]"},
        do: descriptors |> Path.split() |> Enum.at(2)
  end
end
