defmodule LibTmux.Transport.Native.Protocol do
  @moduledoc false

  alias LibTmux.Error
  alias LibTmux.Transport.Native

  def process(executable, arguments, options) do
    options = Keyword.validate!(options, [:cwd, :env])
    cwd = Keyword.fetch!(options, :cwd)
    environment = Keyword.fetch!(options, :env)

    unless is_binary(executable) and Path.type(executable) == :absolute and
             is_binary(cwd) and Path.type(cwd) == :absolute and
             is_list(arguments) and length(arguments) < 256 and
             Enum.all?([executable, cwd | arguments], &string?/1),
           do:
             raise(
               ArgumentError,
               "transport requires an absolute executable/cwd and at most 255 NUL-free argv values"
             )

    unless is_map(environment), do: raise(ArgumentError, "env requires named binary values")
    environment = Map.drop(environment, ["TMUX", "TMUX_PANE"])

    unless map_size(environment) <= 256 and
             Enum.all?(environment, fn {key, value} ->
               string?(key) and byte_size(key) in 1..128 and :binary.match(key, "=") == :nomatch and
                 string?(value)
             end),
           do: raise(ArgumentError, "env requires at most 256 NUL-free named binary values")

    argv = [executable | arguments]

    environment =
      environment |> Enum.sort() |> Enum.map(fn {key, value} -> key <> "=" <> value end)

    payload = [
      Native.encode_string(cwd),
      <<length(argv)::16>>,
      Enum.map(argv, &Native.encode_string/1),
      <<length(environment)::16>>,
      Enum.map(environment, &Native.encode_string/1)
    ]

    if IO.iodata_length(payload) + 7 > 32_768,
      do: raise(ArgumentError, "encoded argv/cwd/environment exceeds 32 KiB")

    IO.iodata_to_binary(payload)
  end

  # Timeout zero is reserved for a persistent child; its owner enforces operation deadlines.
  def open_frame(payload, options) when is_binary(payload) do
    options = Keyword.validate!(options, [:input, :timeout])
    input = Keyword.fetch!(options, :input)
    timeout = Keyword.fetch!(options, :timeout)

    unless input in [:open, :closed] and is_integer(timeout) and timeout in 0..600_000 and
             byte_size(payload) <= 32_761,
           do: raise(ArgumentError, "invalid native open frame")

    <<?O, 3, if(input == :open, do: 1, else: 0), timeout::32, payload::binary>>
  end

  def read_frame(stream, bytes)
      when stream in [:stdout, :stderr] and is_integer(bytes) and bytes in 1..8192,
      do: <<?R, if(stream == :stdout, do: 1, else: 2), bytes::16>>

  def read_frame(_stream, _bytes),
    do: raise(ArgumentError, "native read requires a stream and 1..8192 bytes")

  def write_frame(id, bytes)
      when is_integer(id) and id in 0..4_294_967_295 and is_binary(bytes) and
             byte_size(bytes) in 1..8192,
      do: <<?W, id::32, bytes::binary>>

  def write_frame(_id, _bytes),
    do: raise(ArgumentError, "native write requires a uint32 identity and 1..8192 bytes")

  def close_frame, do: "C"
  def stop_frame, do: "Q"
  def terminal_ack_frame, do: "T"

  def decode(<<?S, pid::32>>) when pid > 0, do: {:ok, {:started, pid}}

  def decode(<<?D, stream, bytes::binary>>) when stream in [1, 2] and byte_size(bytes) in 1..8192,
    do: {:ok, {:data, stream(stream), bytes}}

  def decode(<<?Z, stream>>) when stream in [1, 2], do: {:ok, {:eof, stream(stream)}}

  def decode(<<?A, id::32, count::16, failed>>)
      when count <= 8192 and failed in [0, 1] and (count > 0 or failed == 1),
      do: {:ok, {:written, id, count, if(failed == 0, do: :ok, else: :error)}}

  def decode("C"), do: {:ok, :input_closed}

  def decode(<<?E, reason, status::32>>) when reason in 0..3,
    do: {:ok, {:terminal, reason, status}}

  def decode(<<?F, kind, errno::32>>) when kind in 1..3, do: {:ok, {:failed, kind, errno}}
  def decode(<<?F, 4, 0::32>>), do: {:ok, {:warning, :cleanup_incomplete}}
  def decode(_bytes), do: {:error, %Error{kind: :protocol_error, phase: :parse, path: [:native]}}

  defp stream(1), do: :stdout
  defp stream(2), do: :stderr

  defp string?(value),
    do:
      is_binary(value) and byte_size(value) <= 32_000 and :binary.match(value, <<0>>) == :nomatch
end
