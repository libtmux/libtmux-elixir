defmodule LibTmux.Test.NativePeer do
  @moduledoc false
  alias LibTmux.Deadline
  alias LibTmux.Transport.Native
  alias LibTmux.Transport.Native.Protocol

  def with_process(executable, argv, run) do
    payload = Protocol.process(executable, argv, cwd: "/", env: %{})
    previous = Process.flag(:trap_exit, true)

    try do
      port =
        Port.open({:spawn_executable, Native.executable()}, [:binary, :exit_status, {:packet, 2}])

      Process.put({__MODULE__, port}, %{proof: nil, status: nil})

      try do
        true =
          Port.command(port, Protocol.open_frame(payload, input: :open, timeout: 0), [:nosuspend])

        run.(port)
      after
        try do
          close(port)
        after
          Process.delete({__MODULE__, port})
          close_port(port)
        end
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  def next(port, deadline) do
    receive do
      {^port, {:data, bytes}} ->
        {:ok, event} = Protocol.decode(bytes)

        if match?({:terminal, _, _}, event) or match?({:failed, _, _}, event) do
          remember(port, :proof, event)
          true = Port.command(port, Protocol.terminal_ack_frame(), [:nosuspend])
        end

        event

      {^port, {:exit_status, status}} ->
        remember(port, :status, status)
        {:helper_exit, status}

      {:EXIT, ^port, reason} ->
        {:port_exit, reason}
    after
      Deadline.remaining(deadline) -> raise "native test peer exceeded its deadline"
    end
  end

  def await_exit(port, deadline) do
    case Process.get({__MODULE__, port}) do
      %{proof: proof, status: 0} when not is_nil(proof) ->
        {:retired, proof}

      %{status: status} when not is_nil(status) ->
        raise "native test peer exited without complete proof: #{status}"

      _ ->
        next(port, deadline)
        await_exit(port, deadline)
    end
  end

  def close(port) do
    case Process.get({__MODULE__, port}) do
      %{proof: nil, status: nil} ->
        if Port.info(port), do: Port.command(port, Protocol.stop_frame(), [:nosuspend])

      _ ->
        :ok
    end

    await_exit(port, Deadline.new(750))
  end

  defp remember(port, key, value),
    do: Process.put({__MODULE__, port}, Map.put(Process.get({__MODULE__, port}), key, value))

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
