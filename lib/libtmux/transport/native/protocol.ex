defmodule LibTmux.Transport.Native.Protocol do
  @moduledoc false

  alias LibTmux.Error
  alias LibTmux.Transport.Native

  def process(executable, arguments, options) do
    case prepare_process(executable, arguments, options) do
      {:ok, payload} -> payload
      {:error, error} -> raise ArgumentError, error.details.reason
    end
  end

  def prepare_process(executable, arguments, options) do
    options = Keyword.validate!(options, [:cwd, :env, keep_tmux_context: false])
    cwd = Keyword.fetch!(options, :cwd)
    environment = Keyword.fetch!(options, :env)

    cond do
      not (string?(executable) and Path.type(executable) == :absolute) ->
        invalid(
          :executable,
          "expected an absolute NUL-free executable path of at most 32000 bytes"
        )

      not (string?(cwd) and Path.type(cwd) == :absolute) ->
        invalid(:cwd, "expected an absolute NUL-free cwd of at most 32000 bytes")

      not (is_list(arguments) and length(arguments) < 2048) ->
        invalid(:argv, "expected at most 2047 arguments, excluding the executable")

      not Enum.all?(arguments, &string?/1) ->
        invalid(:argv, "expected NUL-free arguments of at most 32000 bytes each")

      not is_map(environment) ->
        invalid(:env, "expected named binary environment values")

      true ->
        prepare_environment(executable, arguments, cwd, environment, options[:keep_tmux_context])
    end
  end

  # tmux reads TMUX to choose a server when it is given no socket, so a caller
  # that passes none keeps both variables; every other process loses them.
  defp prepare_environment(executable, arguments, cwd, environment, keep_tmux_context) do
    environment =
      if keep_tmux_context === true,
        do: environment,
        else: Map.drop(environment, ["TMUX", "TMUX_PANE"])

    if map_size(environment) <= 256 and
         Enum.all?(environment, fn {key, value} ->
           string?(key) and byte_size(key) in 1..128 and :binary.match(key, "=") == :nomatch and
             string?(value)
         end) do
      encode_process(executable, arguments, cwd, environment)
    else
      invalid(
        :env,
        "expected at most 256 NUL-free values up to 32000 bytes with 1..128-byte names"
      )
    end
  end

  defp encode_process(executable, arguments, cwd, environment) do
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
      do: invalid(:frame, "encoded executable/argv/cwd/environment exceeds 32 KiB"),
      else: {:ok, IO.iodata_to_binary(payload)}
  end

  defp invalid(field, reason),
    do:
      {:error,
       %Error{
         kind: :invalid_command,
         phase: :validation,
         certainty: :no_write,
         path: [:process, field],
         details: %{reason: reason}
       }}

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
