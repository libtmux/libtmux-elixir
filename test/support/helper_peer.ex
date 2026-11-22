defmodule LibTmux.Test.HelperPeer do
  @moduledoc false
  # Drives the private native helper byte by byte over its two-byte length
  # framing, so a test can send frames the library never would and read every
  # frame the helper returns.

  import ExUnit.Assertions

  alias LibTmux.Test.Child
  alias LibTmux.Transport.Native

  @receive_ms 750

  defstruct [:port, :os_pid, :pid]

  @doc "Starts the helper with no child and no frames sent."
  def bare(options \\ []) do
    port =
      Port.open({:spawn_executable, Keyword.get(options, :helper, Native.executable())}, [
        :binary,
        :exit_status,
        {:env,
         [
           {~c"TMUX", false},
           {~c"TMUX_PANE", false},
           {~c"LIBTMUX_SOCKET", false},
           {~c"LIBTMUX_SOCKET_PATH", false}
         ]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Process.put({__MODULE__, port}, "")
    %__MODULE__{port: port, os_pid: os_pid}
  end

  @doc "Starts the helper and one child, and returns once the helper reports its pid."
  def start(argv, options \\ []) do
    peer = bare(options)
    send_frame(peer, open_frame(argv, options))
    <<?S, pid::32>> = receive_frame(peer)
    %{peer | pid: pid}
  end

  def open_frame(argv, options \\ []) do
    timeout = Keyword.get_lazy(options, :timeout, fn -> Child.deadline(700) end)
    stdin = if Keyword.get(options, :stdin, false), do: 1, else: 0
    cwd = Keyword.get(options, :cwd, File.cwd!())

    IO.iodata_to_binary([
      <<?O, 3, stdin, timeout::32>>,
      Native.encode_string(cwd),
      <<length(argv)::16>>,
      Enum.map(argv, &Native.encode_string/1),
      <<0::16>>
    ])
  end

  def send_frame(%{port: port}, data) do
    true = Port.command(port, <<byte_size(data)::16, data::binary>>)
    :ok
  end

  def send_raw(%{port: port}, bytes) do
    true = Port.command(port, bytes)
    :ok
  end

  def grant(peer, stream, size \\ 8192), do: send_frame(peer, <<?R, stream, size::16>>)

  def write(peer, id, bytes), do: send_frame(peer, <<?W, id::32, bytes::binary>>)

  @doc "The next frame, or a failed assertion when none arrives in time."
  def receive_frame(%{port: port} = peer, milliseconds \\ Child.deadline(@receive_ms)) do
    case take(Process.get({__MODULE__, port})) do
      {:ok, frame, rest} ->
        Process.put({__MODULE__, port}, rest)
        frame

      :more ->
        receive do
          {^port, {:data, bytes}} ->
            Process.put({__MODULE__, port}, Process.get({__MODULE__, port}) <> bytes)
            receive_frame(peer, milliseconds)

          {^port, {:exit_status, status}} ->
            flunk("helper exited with #{status} while a frame was expected")
        after
          milliseconds -> flunk("helper response timeout")
        end
    end
  end

  @doc "Whether the helper stays silent for `milliseconds`."
  def silent?(%{port: port}, milliseconds) do
    Process.get({__MODULE__, port}) == "" and
      receive do
        {^port, _event} = event ->
          send(self(), event)
          false
      after
        milliseconds -> true
      end
  end

  @doc "Grants both streams and collects output until the terminal frame."
  def drain(peer) do
    grant(peer, 1)
    grant(peer, 2)
    collect(peer, %{1 => "", 2 => ""})
  end

  defp collect(peer, output) do
    case receive_frame(peer) do
      <<?D, stream, bytes::binary>> ->
        grant(peer, stream)
        collect(peer, Map.update!(output, stream, &(&1 <> bytes)))

      <<?Z, _stream>> ->
        collect(peer, output)

      <<?E, _::binary>> = terminal ->
        finish(peer)
        {output, terminal}

      other ->
        flunk("unexpected frame #{inspect(other)}")
    end
  end

  @doc "Cancels the child and returns the terminal frame, collecting trailing frames."
  def cancel(peer) do
    send_frame(peer, "Q")
    terminal = until_terminal(peer, [])
    finish(peer)
    terminal
  end

  defp until_terminal(peer, seen) do
    case receive_frame(peer) do
      <<?E, _::binary>> = terminal ->
        terminal

      <<kind, _::binary>> = frame when kind in [?D, ?Z, ?A, ?C] ->
        until_terminal(peer, [frame | seen])

      other ->
        flunk("unexpected frame #{inspect(other)}")
    end
  end

  @doc "Acknowledges the terminal frame and waits for the helper to exit 0 with nothing after it."
  def finish(peer, acknowledge? \\ true) do
    if acknowledge?, do: send_frame(peer, "T")
    assert exit_status(peer, @receive_ms) == 0, "the helper did not exit 0"
    assert Process.get({__MODULE__, peer.port}) == "", "frames followed the terminal frame"
  end

  @doc "Waits for the helper's exit status, keeping any frames it sent first."
  def exit_status(%{port: port}, milliseconds) do
    receive do
      {^port, {:data, bytes}} ->
        Process.put({__MODULE__, port}, Process.get({__MODULE__, port}) <> bytes)
        exit_status(%{port: port}, milliseconds)

      {^port, {:exit_status, status}} ->
        status
    after
      milliseconds -> flunk("the helper did not exit in #{milliseconds}ms")
    end
  end

  def close(%{port: port}) do
    if Port.info(port), do: Port.close(port)
    Process.delete({__MODULE__, port})
    :ok
  end

  # One length-prefixed frame, or :more when the buffer holds less.
  defp take(<<size::16, frame::binary-size(size), rest::binary>>) when size > 0,
    do: {:ok, frame, rest}

  defp take(_buffer), do: :more
end
