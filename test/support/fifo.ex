defmodule LibTmux.Test.Fifo do
  @moduledoc false
  # Receives the bytes a test program writes to a named pipe. `cat` is the
  # reader, so the test gets port messages instead of polling a file.

  def open(path) do
    {_output, 0} = System.cmd("mkfifo", [path])
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, args: [path]])
    Process.put({__MODULE__, port}, "")
    port
  end

  @doc "Reads exactly `size` bytes, or returns `{:error, :timeout, received}`."
  def recv(port, size, milliseconds) do
    deadline = System.monotonic_time(:millisecond) + milliseconds
    fill(port, size, deadline)
  end

  def close(port) do
    if Port.info(port), do: Port.close(port)
    Process.delete({__MODULE__, port})
    :ok
  end

  defp fill(port, size, deadline) do
    buffer = Process.get({__MODULE__, port})

    if byte_size(buffer) >= size do
      <<bytes::binary-size(^size), rest::binary>> = buffer
      Process.put({__MODULE__, port}, rest)
      {:ok, bytes}
    else
      receive do
        {^port, {:data, data}} ->
          Process.put({__MODULE__, port}, buffer <> data)
          fill(port, size, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          {:error, :timeout, buffer}
      end
    end
  end
end
