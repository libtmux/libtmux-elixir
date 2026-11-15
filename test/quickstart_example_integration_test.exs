defmodule LibTmux.QuickstartExampleIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.Test.TmuxPath

  @moduletag :integration
  @moduletag reason: "Runs the quickstart against a private tmux server"
  @moduletag timeout: 180_000

  @root Path.expand("..", __DIR__)
  @kept_environment ~w(PATH HOME ERL_FLAGS MIX_HOME HEX_HOME CC)

  setup_all do
    tmux = TmuxPath.executable()
    base = TmuxPath.private_directory(System.tmp_dir!(), "lqx")
    on_exit(fn -> File.rm_rf!(base) end)

    # Only the dependency changes: the published pin becomes this checkout.
    published = ~s|Mix.install([{:libtmux, "~> 0.1.2"}])|
    core = System.get_env("LIBTMUX_QUICKSTART_PACKAGE", @root)
    installed = ~s|Mix.install([{:libtmux, path: #{inspect(core)}}])|
    source = File.read!(Path.join(core, "examples/quickstart.exs"))
    assert String.starts_with?(source, published <> "\n")
    program = Path.join(base, "quickstart.exs")
    File.write!(program, installed <> String.replace_prefix(source, published, ""))

    context = %{
      base: base,
      tmux: tmux,
      program: program,
      install: Path.join(base, "install")
    }

    # Compile once, so the asserted runs print only the program's output.
    {output, status} = run(context, base, ["-e", installed])
    assert status == 0, output
    context
  end

  setup context do
    tmp = TmuxPath.private_directory(context.base, "t")
    on_exit(fn -> stop_leftovers(tmp) end)
    {:ok, tmp: tmp}
  end

  test "prints the topology and leaves nothing behind", context do
    assert {"demo: 2 windows, 3 panes\n", 0} = run_example(context, context.program)

    assert_clean(context.tmp)
  end

  test "an exception in the program stops the server and removes the directory", context do
    source = File.read!(context.program)
    failing = Path.join(context.tmp, "failing.exs")

    marker = ~S|IO.puts("#{session.name}|
    broken = String.replace(source, marker, ~S|raise "boom"; | <> marker)
    refute broken == source
    File.write!(failing, broken)

    assert {output, 1} = run_example(context, failing)
    assert output =~ "** (RuntimeError) boom"

    assert_clean(context.tmp)
  end

  test "a tmux that cannot start a server fails without leaving a directory", context do
    assert {output, 1} = run_example(context, context.program, "/bin/false")

    assert output =~ "server_start_failed"
    assert_clean(context.tmp)
  end

  test "the probes see a live server and then its exit", context do
    {:ok, server} = LibTmux.Server.start(executable: context.tmux, root: context.tmp)
    assert [_ | _] = Path.wildcard(Path.join(context.tmp, "libtmux-*"))
    assert [_ | _] = listeners(context.tmp)
    assert [_ | _] = holders(context.tmp)

    assert :ok = LibTmux.Server.stop(server)
    assert_clean(context.tmp)
  end

  # The run leaves no directory under its TMPDIR, no listening socket and no
  # process that names the TMPDIR on its command line.
  defp assert_clean(tmp) do
    assert Path.wildcard(Path.join(tmp, "libtmux-*")) == []
    assert listeners(tmp) == []
    assert holders(tmp) == []
  end

  # A plain child process, not OneShot: OneShot retires every descendant on
  # exit, which would hide a server the example forgot to stop.
  defp run_example(context, program, tmux \\ nil) do
    run(context, context.tmp, [program], tmux || context.tmux)
  end

  defp run(context, directory, arguments, tmux \\ nil) do
    bin = Path.join(directory, "bin")

    environment =
      (tmux || context.tmux)
      |> TmuxPath.environment(bin, directory)
      |> Map.take(@kept_environment ++ ["TMPDIR"])
      |> Map.merge(%{
        "MIX_INSTALL_DIR" => context.install,
        "HEX_OFFLINE" => "1",
        "LC_ALL" => "C.UTF-8"
      })

    System.cmd(System.find_executable("elixir"), arguments,
      cd: directory,
      env: Enum.to_list(environment),
      stderr_to_stdout: true
    )
  end

  # A failed run may leave a server. Find it by its socket, never by name.
  defp stop_leftovers(tmp) do
    for pid <- holders(tmp), do: System.cmd("kill", ["-KILL", pid])
    File.rm_rf!(tmp)
  end

  defp listeners(prefix) do
    "/proc/net/unix"
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_, _, _, _, _, _, _inode, path] ->
          if String.contains?(path, prefix), do: [path], else: []

        _other ->
          []
      end
    end)
  end

  defp holders(prefix) do
    for cmdline <- Path.wildcard("/proc/[0-9]*/cmdline"),
        {:ok, text} <- [File.read(cmdline)],
        String.contains?(text, prefix),
        do: cmdline |> Path.split() |> Enum.at(2)
  end
end
