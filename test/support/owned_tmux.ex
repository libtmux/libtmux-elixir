defmodule LibTmux.Test.OwnedTmux do
  @moduledoc false
  # A private tmux server for one test, started and stopped through the
  # library's own Server.start/1 and Server.stop/2. It runs one `cat` pane in
  # the session `fixture`. The fixture process owns the server, so killing the
  # fixture retires the server too.

  use GenServer

  @call_ms 30_000

  alias LibTmux.{Command, Server}
  alias LibTmux.Test.{Processes, TmuxPath}
  alias LibTmux.Transport.OneShot

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def info(fixture), do: GenServer.call(fixture, :info)
  def command(fixture, argv), do: GenServer.call(fixture, {:command, argv}, @call_ms)
  def attach(fixture), do: GenServer.call(fixture, :attach, @call_ms)
  def close(fixture), do: GenServer.call(fixture, :close, @call_ms)
  def alive?(fixture), do: GenServer.call(fixture, :alive)

  def watch_exit(info), do: watch_processes([info.server_pid, info.pane_pid])

  @doc "Names live processes so `await_exit/1` can wait for those exact processes."
  def watch_processes(pids) when is_list(pids) and pids != [],
    do: Enum.map(pids, &Processes.identity!/1)

  def await_exit(watched) do
    case Processes.await_exit(watched) do
      :ok -> :ok
      {:alive, pids} -> raise "owned processes did not exit: #{inspect(pids)}"
    end
  end

  @impl true
  def init(options) do
    executable = Keyword.get_lazy(options, :executable, &TmuxPath.executable/0)
    {:ok, server} = Server.start(executable: executable)

    {:ok, %{stdout: pane}} =
      Server.run(
        server,
        Command.new("new-session", [
          "-d",
          "-s",
          "fixture",
          "-P",
          "-F",
          ~S"#{pane_pid}",
          "/bin/cat",
          "--"
        ])
      )

    {:ok, %{stdout: pid}} = Server.run(server, Command.new("display-message", ["-p", ~S"#{pid}"]))
    server_pid = pid |> String.trim() |> String.to_integer()
    pane_pid = pane |> String.trim() |> String.to_integer()
    {:os_pid, helper_pid} = Port.info(:sys.get_state(server.daemon).port, :os_pid)

    {:ok,
     %{
       server: server,
       executable: executable,
       info: %{
         socket: server.socket,
         server_pid: server_pid,
         pane_pid: pane_pid,
         helper_pid: helper_pid
       },
       identities: [Processes.identity!(server_pid), Processes.identity!(pane_pid)],
       clients: [],
       closed: nil
     }}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  def handle_call({:command, argv}, _from, %{closed: nil} = state) do
    {:ok, result} =
      OneShot.run(state.executable, ["-N", "-S", state.server.socket | argv], env: clean_env())

    {:reply, {result.stdout <> result.stderr, result.exit_status}, state}
  end

  def handle_call(:attach, _from, %{closed: nil} = state) do
    {port, pid} = attach_client(state)
    client = {port, Processes.identity!(pid)}
    {:reply, %{pid: pid}, %{state | clients: [client | state.clients]}}
  end

  def handle_call(:alive, _from, %{closed: nil} = state),
    do: {:reply, Enum.all?(state.identities, &Processes.alive?/1), state}

  def handle_call(:close, _from, %{closed: nil} = state) do
    result = stop(state)
    {:reply, {:ok, result}, %{state | closed: result}}
  end

  def handle_call(:close, _from, state), do: {:reply, {:ok, state.closed}, state}

  @impl true
  def handle_info({port, _event}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{closed: nil} = state), do: stop(state)
  def terminate(_reason, _state), do: :ok

  defp stop(state) do
    clients = for {port, identity} <- state.clients, do: close_client(port, identity)
    stopped = Server.stop(state.server)
    exited = Processes.await_exit(state.identities)

    %{
      server_exited: stopped == :ok and exited == :ok,
      pane_exited: exited == :ok,
      clients_exited: Enum.all?(clients, &(&1 == :ok))
    }
  end

  # A control client attached to the fixture session, held open on stdin.
  defp attach_client(state) do
    port =
      Port.open({:spawn_executable, state.executable}, [
        :binary,
        :exit_status,
        {:env,
         [
           {~c"TMUX", false},
           {~c"TMUX_PANE", false},
           {~c"LIBTMUX_SOCKET", false},
           {~c"LIBTMUX_SOCKET_PATH", false}
         ]},
        {:args,
         ["-N", "-C", "-S", state.server.socket, "attach-session", "-t", "$0", "-f"] ++
           ["no-output,ignore-size"]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    await_attached(port, "", System.monotonic_time(:millisecond) + 750)
    {port, pid}
  end

  defp await_attached(port, data, deadline) do
    receive do
      {^port, {:data, chunk}} ->
        data = data <> chunk

        cond do
          String.contains?(data, "\n%error ") -> raise "owned client attach failed"
          String.contains?(data, "\n%end ") -> :ok
          byte_size(data) > 65_536 -> raise "owned client startup exceeded byte limit"
          true -> await_attached(port, data, deadline)
        end

      {^port, {:exit_status, _status}} ->
        raise "owned client exited before attach acknowledgment"
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "owned client did not acknowledge attachment"
    end
  end

  defp close_client(port, identity) do
    if Port.info(port), do: Port.close(port)
    Processes.await_exit([identity])
  end

  defp clean_env, do: TmuxPath.clean_env()
end
