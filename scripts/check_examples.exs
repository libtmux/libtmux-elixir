defmodule LibTmux.ExampleCheck do
  @moduledoc false
  # Runs the shipped examples from the packed package. Each example starts and
  # stops its own tmux server through the library; this check puts the tmux
  # under test first on PATH, gives the program a TMPDIR of its own, and proves
  # afterwards that no directory, socket or process of that server is left.

  alias LibTmux.Transport.OneShot

  def run(package, consumer) do
    ebin = Path.join(package, "_build/prod/lib/libtmux/ebin")
    elixir = System.find_executable("elixir") || raise "Elixir is required"

    executable =
      System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux") ||
        raise "packed examples require tmux"

    code = ~S"""
    [expected, example | arguments] = System.argv()
    System.argv(arguments)
    {:ok, _} = Application.ensure_all_started(:libtmux)
    Code.require_file(example)
    for module <- Application.spec(:libtmux, :modules) do
      path = module |> :code.which() |> List.to_string() |> Path.dirname() |> Path.expand()
      true = path == Path.expand(expected)
    end
    """

    context = %{
      package: package,
      consumer: consumer,
      ebin: ebin,
      elixir: elixir,
      executable: executable,
      code: code
    }

    options = [cwd: consumer, env: pure_env(), timeout: 5000, max_total_bytes: 16_384]

    for name <- ["query_values", "encoding_values"] do
      example = Path.join(package, "examples/#{name}.exs")

      {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
        OneShot.run(elixir, ["-pa", ebin, "-e", code, "--", ebin, example], options)

      true = JSON.decode!(stdout) == %{name => "ok"}
      IO.puts("PASS: packed #{name}; executed public reference examples")
    end

    for name <- [
          "readme",
          "private_server",
          "choose_server",
          "filtering",
          "capture_and_filter",
          "one_shot_actions",
          "managed_control",
          "capture_and_read"
        ] do
      [result] = example(context, Path.join(package, "examples/#{name}.exs"))
      check(name, result)
      IO.puts("PASS: packed #{name}; owned server and pane processes exited")
    end

    [normal, faults] =
      cases(context, "recovery_cases.exs", Path.join(package, "examples/recover_command.exs"))

    check("recover_command", normal)

    %{"recovery_cases" => "ok", "inspected_before_scope_exit" => true, "native_exited" => true} =
      faults

    IO.puts(
      "PASS: packed recovery example; admission, uncertainty, context loss and primary cleanup evidence"
    )

    [normal, faults] =
      cases(
        context,
        "supervision_cases.exs",
        Path.join(package, "examples/supervised_control.exs")
      )

    check("supervised_control", normal)

    %{"supervision_cases" => "ok", "native_exited" => true, "unknown_cleanup_refused" => true} =
      faults

    IO.puts(
      "PASS: packed supervision recipe; stale handles, explicit recovery and unknown cleanup"
    )

    singleton_argv(context)
    failure_paths(context)
    check_mix_recipes(context, options)

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "test",
          "test/quickstart_example_integration_test.exs",
          "--include",
          "integration",
          "--warnings-as-errors",
          "--seed",
          "624498"
        ],
        env: [{"MIX_ENV", "test"}, {"LIBTMUX_QUICKSTART_PACKAGE", package}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("packed quickstart failed: #{output}")
    IO.puts("PASS: packed standalone quickstart; success, failure and process retirement")
  end

  # The packed library runs in a VM of its own, as a consumer would run it.
  defp pure_env do
    Map.drop(System.get_env(), [
      "TMUX",
      "TMUX_PANE",
      "ERL_LIBS",
      "ELIXIR_ERL_OPTIONS",
      "ERL_AFLAGS",
      "ERL_ZFLAGS"
    ])
  end

  # A fresh TMPDIR and a `tmux` first on PATH, so the program starts the tmux
  # under test and every directory it makes lands where this check can see it.
  defp sandbox(context) do
    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-example-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir!(Path.join(root, "tmp"))
    File.chmod!(root, 0o700)
    File.ln_s!(context.executable, Path.join([root, "bin", "tmux"]))

    env =
      pure_env()
      |> Map.put("PATH", Path.join(root, "bin") <> ":" <> System.get_env("PATH", ""))
      |> Map.put("TMPDIR", Path.join(root, "tmp"))

    %{root: root, tmp: Path.join(root, "tmp"), env: Enum.to_list(env)}
  end

  # Runs one program as a plain child process and returns its JSON lines. A
  # plain child, not OneShot: OneShot retires every descendant on exit and would
  # hide a server the program forgot to stop.
  defp program(context, arguments, expected_status \\ 0) do
    sandbox = sandbox(context)

    try do
      {output, status} =
        System.cmd(context.elixir, arguments,
          cd: context.consumer,
          env: sandbox.env,
          stderr_to_stdout: true
        )

      if status != expected_status,
        do: raise("exit #{status}, expected #{expected_status}: #{output}")

      check_cleanup(sandbox.tmp)
      {output, sandbox}
    after
      File.rm_rf!(sandbox.root)
    end
  end

  defp json_lines(output),
    do: output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp example(context, example) do
    {output, _sandbox} =
      program(context, ["-pa", context.ebin, "-e", context.code, "--", context.ebin, example])

    json_lines(output)
  end

  defp cases(context, script, example) do
    {output, _sandbox} =
      program(context, [
        "-pa",
        context.ebin,
        Path.expand("../test/support/#{script}", __DIR__),
        example
      ])

    json_lines(output)
  end

  defp singleton_argv(context) do
    {output, _sandbox} =
      program(context, [
        "-pa",
        context.ebin,
        Path.expand("../test/support/split_argv_lifetime.exs", __DIR__),
        context.elixir,
        context.ebin,
        context.package
      ])

    [result] = json_lines(output)

    %{
      "singleton_argv" => "ok",
      "creating_beam_exited" => true,
      "respawn" => "ok",
      "removed_copy_respawn_exit" => 1
    } = result

    IO.puts("PASS: packed singleton argv survives caller exit; retained-path respawn qualified")
  end

  # A failing caller still reaches teardown; a halted VM leaves its server to
  # the native helper, which retires it.
  defp failure_paths(context) do
    start = ~S"""
    {:ok, _} = Application.ensure_all_started(:libtmux)
    alias LibTmux.Server
    tmux = System.find_executable("tmux")
    """

    raising =
      start <>
        ~S"""
        Server.with_owned([executable: tmux], fn server ->
          {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
          raise "caller failed"
        end)
        """

    {output, _sandbox} = program(context, ["-pa", context.ebin, "-e", raising], 1)
    true = String.contains?(output, "caller failed")
    IO.puts("PASS: owned example server retires after caller failure")

    halting =
      start <>
        ~S"""
        Server.with_owned([executable: tmux], fn server ->
          {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
          System.halt(7)
        end)
        """

    sandbox = sandbox(context)

    try do
      {_output, 7} =
        System.cmd(context.elixir, ["-pa", context.ebin, "-e", halting],
          cd: context.consumer,
          env: sandbox.env,
          stderr_to_stdout: true
        )

      # The directory stays because the VM never ran its stop step; the server does not.
      [] = listeners(sandbox.tmp)
      [] = holders(sandbox.tmp)
    after
      File.rm_rf!(sandbox.root)
    end

    IO.puts("PASS: a halted caller leaves no server behind")
  end

  defp check_mix_recipes(context, options) do
    package = context.package
    consumer = context.consumer

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule ExampleConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :example_consumer, version: "0.1.0",
        deps: [{:libtmux, path: #{inspect(package)}}]]
      def application, do: []
    end
    """)

    mix = System.find_executable("mix") || raise "Mix is required"

    {_output, 0} =
      System.cmd(mix, ["compile", "--warnings-as-errors"],
        cd: consumer,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    File.cp!(
      Path.join(package, "examples/capture_and_filter.exs"),
      Path.join(consumer, "capture_and_filter.exs")
    )

    File.cp_r!(Path.join(package, "examples"), Path.join(consumer, "examples"))
    _ = options

    for {name, script} <- [
          {"readme", "examples/readme.exs"},
          {"capture_and_filter", "capture_and_filter.exs"},
          {"managed_control", "examples/managed_control.exs"},
          {"recover_command", "examples/recover_command.exs"}
        ] do
      sandbox = sandbox(context)

      try do
        env = [{"MIX_ENV", "prod"} | sandbox.env]

        {output, 0} =
          System.cmd(mix, ["run", script], cd: consumer, env: env, stderr_to_stdout: true)

        # Mix prints compile progress before the program's own line.
        [result] =
          output
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "{"))
          |> Enum.map(&JSON.decode!/1)

        check(name, result)
        check_cleanup(sandbox.tmp)
      after
        File.rm_rf!(sandbox.root)
      end
    end

    IO.puts("PASS: documented Mix commands in a separate installed consumer")
  end

  # Nothing of the example's server may remain: no directory, no listening
  # socket and no process that names the directory on its command line.
  defp check_cleanup(tmp) do
    [] = Path.wildcard(Path.join(tmp, "libtmux-*"))
    [] = listeners(tmp)
    [] = holders(tmp)
    :ok
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

  defp check("capture_and_filter", %{"active_panes" => ["%0"]}), do: :ok

  defp check("private_server", %{
         "session" => "$0",
         "created_window" => "@1",
         "windows_before_kill" => 2,
         "remaining_windows" => ["@0"]
       }),
       do: :ok

  defp check("choose_server", %{
         "by_path" => "/run/user/1000/work.sock",
         "by_name" => "work",
         "from_variable" => "work",
         "from_path_variable" => "/tmp/w.sock",
         "default" => "tmux chooses"
       }),
       do: :ok

  defp check("filtering", %{"filtering" => "ok"}), do: :ok

  defp check("readme", %{
         "active_panes" => ["%0"],
         "window" => "editor",
         "created_pane" => "%1",
         "connection_retired" => true
       }),
       do: :ok

  defp check("one_shot_actions", %{"created_pane" => "%1", "captured_bytes" => bytes})
       when bytes in 0..4096, do: :ok

  defp check("managed_control", %{
         "created_pane" => "%1",
         "repeated_reads" => 128,
         "connection_retired" => true
       }),
       do: :ok

  defp check("supervised_control", %{
         "supervised_control" => "completed",
         "explicit_reconnect" => true
       }),
       do: :ok

  defp check("recover_command", %{
         "recovery_example" => "completed",
         "connection_retired" => true
       }),
       do: :ok

  defp check("capture_and_read", %{
         "session" => "$0",
         "window" => "@0",
         "pane" => "%0",
         "oneShot" => "%0",
         "control" => "%0",
         "connectionRetired" => true
       }),
       do: :ok
end
