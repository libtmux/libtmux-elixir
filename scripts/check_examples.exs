defmodule LibTmux.ExampleCheck do
  @moduledoc false

  alias LibTmux.Test.OwnedTmux
  alias LibTmux.Transport.OneShot

  def run(package, consumer) do
    unless Code.ensure_loaded?(OwnedTmux),
      do: raise(ArgumentError, "packed examples require MIX_ENV=test and owned test fixtures")

    example = Path.join(package, "examples/capture_and_read.exs")
    ebin = Path.join(package, "_build/prod/lib/libtmux/ebin")
    true = File.regular?(example)
    elixir = System.find_executable("elixir") || raise "Elixir is required"

    code = ~S"""
    [expected, example | arguments] = System.argv()
    System.argv(arguments)
    Code.require_file(example)
    for module <- Application.spec(:libtmux, :modules) do
      path = module |> :code.which() |> List.to_string() |> Path.dirname() |> Path.expand()
      true = path == Path.expand(expected)
    end
    """

    executable =
      System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux") ||
        raise "packed examples require tmux"

    {:ok, fixture} = OwnedTmux.start_link([])
    fixture_monitor = Process.monitor(fixture)
    info = OwnedTmux.info(fixture)

    try do
      {:ok, %{stdout: stdout, stderr: "", exit_status: 0, cleanup: :retired}} =
        OneShot.run(
          elixir,
          [
            "-pa",
            ebin,
            "-e",
            code,
            "--",
            ebin,
            example,
            executable,
            info.socket,
            "$0"
          ],
          cwd: consumer,
          env:
            Map.drop(System.get_env(), [
              "TMUX",
              "TMUX_PANE",
              "ERL_LIBS",
              "ELIXIR_ERL_OPTIONS",
              "ERL_AFLAGS",
              "ERL_ZFLAGS"
            ]),
          timeout: 5000,
          max_total_bytes: 8192
        )

      {:ok,
       %{
         "session" => "$0",
         "window" => "@0",
         "pane" => "%0",
         "oneShot" => "%0",
         "control" => "%0",
         "connectionRetired" => true
       }} = JSON.decode(stdout)

      true = OwnedTmux.alive?(fixture)
      IO.write(stdout)
    after
      try do
        {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
          OwnedTmux.close(fixture)
      after
        :ok = GenServer.stop(fixture, :normal, 800)

        receive do
          {:DOWN, ^fixture_monitor, :process, ^fixture, :normal} -> :ok
        after
          800 -> raise "example fixture owner did not exit"
        end
      end
    end

    IO.puts("PASS: packed public example; connection retired and owned tmux processes exited")
  end
end
