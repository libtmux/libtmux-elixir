defmodule LibTmux.Capture.Row do
  @moduledoc false
  alias LibTmux.{Codec, Error, Format}

  def format(variables) when is_list(variables) and length(variables) in 1..16 do
    "r1:#{length(variables)}\t" <> Enum.map_join(variables, "\t", &Format.field/1)
  end

  def decode(response, count, options \\ [])
      when is_binary(response) and count in 1..16 do
    options = Keyword.validate!(options, max_bytes: 65_536)
    limit = options[:max_bytes]
    unless is_integer(limit) and limit > 0, do: raise(ArgumentError, "invalid row byte limit")
    marker = "r1:#{count}"

    cond do
      byte_size(response) > limit ->
        error(:resource_limit, :row_bytes)

      byte_size(response) == 0 or :binary.last(response) != 10 ->
        error(:codec_error, :row_framing)

      true ->
        body = binary_part(response, 0, byte_size(response) - 1)

        case :binary.split(body, "\t", [:global]) do
          [^marker | fields] when length(fields) == count -> decode_fields(fields, limit)
          _ -> error(:codec_error, :row_fields)
        end
    end
  end

  defp decode_fields(fields, limit) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {field, index}, {:ok, values} ->
      case Codec.decode_field(field <> "\n", :bytes, encoding: :escaped_v1, max_bytes: limit) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, error} -> {:halt, {:error, %{error | path: [index]}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp error(kind, reason),
    do: {:error, %Error{kind: kind, phase: :capture, details: %{reason: reason}}}
end
