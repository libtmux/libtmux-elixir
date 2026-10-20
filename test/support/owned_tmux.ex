defmodule LibTmux.Test.OwnedTmux do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def info(fixture), do: GenServer.call(fixture, :info)
  def command(fixture, argv), do: GenServer.call(fixture, {:command, argv})
  def close(fixture), do: GenServer.call(fixture, :close)

  def watch_exit(info) do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        {:args,
         [
           Path.join(__DIR__, "owned_tmux.py"),
           "--watch",
           Integer.to_string(info.server_pid),
           Integer.to_string(info.pane_pid),
           Integer.to_string(info.helper_pid)
         ]}
      ])

    %{"kind" => "watching"} = receive_json(port)
    port
  end

  def await_exit(port) do
    %{"kind" => "exited"} = receive_json(port)

    receive do
      {^port, {:exit_status, 0}} -> :ok
    after
      750 -> raise "fixture exit watcher did not exit"
    end
  end

  @impl true
  def init(options) do
    executable = Keyword.get_lazy(options, :executable, &default_executable/0)
    python = System.find_executable("python3") || raise "real tmux tests require Python 3"

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        {:args, [Path.join(__DIR__, "owned_tmux.py"), executable]},
        {:env, [{~c"TMUX", false}, {~c"TMUX_PANE", false}]}
      ])

    %{"kind" => "ready", "socket" => socket, "server_pid" => server, "pane_pid" => pane} =
      receive_json(port)

    {:os_pid, helper} = Port.info(port, :os_pid)

    {:ok,
     %{
       port: port,
       socket: socket,
       server_pid: server,
       pane_pid: pane,
       helper_pid: helper,
       closed: nil
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:socket, :server_pid, :pane_pid, :helper_pid]), state}
  end

  def handle_call({:command, argv}, _from, %{closed: nil} = state) do
    %{"kind" => "reply", "data" => data, "status" => status} =
      request(state.port, %{op: "command", argv: Enum.map(argv, &Base.encode64/1)})

    {:reply, {Base.decode64!(data), status}, state}
  end

  def handle_call(:close, _from, %{closed: nil} = state) do
    result = stop(state.port)
    {:reply, {:ok, result}, %{state | port: nil, closed: result}}
  end

  def handle_call(:close, _from, state), do: {:reply, {:ok, state.closed}, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, %{port: port}), do: stop(port)

  defp stop(port) do
    %{"kind" => "stopped", "server_exit" => status, "pane_exited" => pane_exited} =
      request(port, %{op: "stop"})

    receive do
      {^port, {:exit_status, 0}} -> %{server_exit: status, pane_exited: pane_exited}
    after
      750 -> raise "owned fixture helper did not exit"
    end
  end

  defp request(port, payload) do
    true = Port.command(port, [JSON.encode_to_iodata!(payload), "\n"])
    receive_json(port)
  end

  defp receive_json(port) do
    receive do
      {^port, {:data, {:eol, data}}} -> JSON.decode!(data)
      {^port, {:data, {:noeol, _data}}} -> raise "fixture response exceeds byte limit"
      {^port, {:exit_status, status}} -> raise "fixture helper exited: #{status}"
    after
      950 -> raise "fixture helper did not respond"
    end
  end

  defp default_executable do
    System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux") ||
      raise "real tmux tests require an explicit tmux binary or tmux on PATH"
  end
end
