defmodule LibTmux.ExampleCheck do
  @moduledoc false
  alias LibTmux.Transport.OneShot

  def run(package, consumer) do
    ebin = Path.join(package, "_build/prod/lib/libtmux/ebin")
    elixir = System.find_executable("elixir") || raise "Elixir is required"
    python = System.find_executable("python3") || raise "Python 3 is required"

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

    runner = Path.join(package, "examples/owned_server.py")

    env =
      Map.drop(System.get_env(), [
        "TMUX",
        "TMUX_PANE",
        "ERL_LIBS",
        "ELIXIR_ERL_OPTIONS",
        "ERL_AFLAGS",
        "ERL_ZFLAGS"
      ])

    options = [cwd: consumer, env: env, timeout: 5000, max_total_bytes: 16_384]

    for name <- ["query_values", "encoding_values"] do
      example = Path.join(package, "examples/#{name}.exs")

      {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
        OneShot.run(elixir, ["-pa", ebin, "-e", code, "--", ebin, example], options)

      true = JSON.decode!(stdout) == %{name => "ok"}
      IO.puts("PASS: packed #{name}; executed public reference examples")
    end

    for name <- ["capture_and_filter", "one_shot_actions", "managed_control", "capture_and_read"] do
      example = Path.join(package, "examples/#{name}.exs")

      {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
        OneShot.run(
          python,
          [runner, "--run", executable, elixir, "-pa", ebin, "-e", code, "--", ebin, example],
          options
        )

      [result, cleanup] = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      %{"caller_exit" => 0} = cleanup
      check(name, result)
      check_cleanup(cleanup)
      IO.puts("PASS: packed #{name}; owned server and pane processes exited")
    end

    {:ok, %{stdout: stdout, stderr: "", exit_status: 7, cleanup: :retired}} =
      OneShot.run(
        python,
        [runner, "--run", executable, python, "-c", "raise SystemExit(7)"],
        options
      )

    %{"caller_exit" => 7} = cleanup = JSON.decode!(stdout)
    check_cleanup(cleanup)
    IO.puts("PASS: owned example server retires after caller failure")

    {:ok, %{stdout: stdout, stderr: "", exit_status: 7, cleanup: :retired}} =
      OneShot.run(
        python,
        [
          runner,
          "--run",
          executable,
          python,
          "-c",
          "import os,sys; os.unlink(sys.argv[-2]); raise SystemExit(7)"
        ],
        options
      )

    %{"caller_exit" => 7, "cleanup_errors" => errors, "pane_exited" => true, "server_exit" => -9} =
      JSON.decode!(stdout)

    true = errors != []
    IO.puts("PASS: caller failure survives separate teardown failure evidence")

    check_mix_recipes(package, consumer, python, executable, options)
  end

  defp check_mix_recipes(package, consumer, python, executable, options) do
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
    options = Keyword.update!(options, :env, &Map.put(&1, "MIX_ENV", "prod"))

    for {name, script} <- [
          {"capture_and_filter", "capture_and_filter.exs"},
          {"managed_control", "examples/managed_control.exs"}
        ] do
      {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
        OneShot.run(
          python,
          ["examples/owned_server.py", "--run", executable, mix, "run", script],
          options
        )

      [result, cleanup] = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      check(name, result)
      %{"caller_exit" => 0} = cleanup
      check_cleanup(cleanup)
    end

    IO.puts("PASS: documented Mix commands in a separate installed consumer")
  end

  defp check("capture_and_filter", %{"active_panes" => ["%0"]}), do: :ok

  defp check("one_shot_actions", %{"created_pane" => "%1", "captured_bytes" => bytes})
       when bytes in 0..4096, do: :ok

  defp check("managed_control", %{
         "created_pane" => "%1",
         "repeated_reads" => 128,
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

  defp check_cleanup(%{
         "kind" => "stopped",
         "server_exit" => 0,
         "pane_exited" => true,
         "clients_exited" => true,
         "borrowed_survived" => true,
         "caller_error" => nil,
         "cleanup_errors" => []
       }),
       do: :ok
end
