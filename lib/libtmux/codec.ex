defmodule LibTmux.Codec do
  @moduledoc """
  Decodes bounded field responses and control-output bytes.

  A field response contains one free-form field and one framing newline.
  The default raw mode removes only its framing newline and requires a
  separately qualified raw source. Use `encoding: :escaped_v1` for output
  produced by `LibTmux.Format.field/1`, including tmux 3.4's print path.
  This is a conservative response codec, not a multi-field row codec.
  """

  alias LibTmux.Error

  @typedoc "The required decoded field category; string additionally requires valid UTF-8."
  @type field_type :: :bytes | :string | :integer | :boolean
  @typedoc "Field framing and value validation options; min and max apply only to integer fields."
  @type field_option ::
          {:encoding, :raw | :escaped_v1}
          | {:max_bytes, pos_integer()}
          | {:min | :max, integer() | nil}

  @doc """
  Removes one framing newline and validates the complete field value.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec decode_field(binary(), :bytes | :string, [field_option()]) ::
          {:ok, binary()} | {:error, Error.t()}
  @spec decode_field(binary(), :integer, [field_option()]) ::
          {:ok, integer()} | {:error, Error.t()}
  @spec decode_field(binary(), :boolean, [field_option()]) ::
          {:ok, boolean()} | {:error, Error.t()}
  def decode_field(response, type, options \\ [])

  # Literal category clauses improve consumer type inference.
  for type <- [:bytes, :string, :integer, :boolean] do
    def decode_field(response, unquote(type), options) when is_binary(response) do
      with {:ok, value} <- decode_framed(response, options) do
        decode_value(value, unquote(type), options)
      end
    end
  end

  def decode_field(response, type, options) when is_binary(response) do
    with {:ok, value} <- decode_framed(response, options), do: decode_value(value, type, options)
  end

  @doc """
  Decodes tmux's three-digit octal output escapes as bytes.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec decode_output(binary(), [{:max_bytes, pos_integer()}]) ::
          {:ok, binary()} | {:error, Error.t()}
  def decode_output(value, options \\ []) when is_binary(value) do
    if byte_size(value) > max_bytes(options) do
      error(:resource_limit, :output_bytes)
    else
      output(value, <<>>)
    end
  end

  defp decode_framed(response, options) do
    cond do
      byte_size(response) > max_bytes(options) ->
        error(:resource_limit, :field_bytes)

      byte_size(response) == 0 or :binary.last(response) != 10 ->
        error(:codec_error, :missing_framing_newline)

      true ->
        value = binary_part(response, 0, byte_size(response) - 1)
        decode_encoding(value, Keyword.get(options, :encoding, :raw))
    end
  end

  defp decode_encoding(value, :raw), do: {:ok, value}
  defp decode_encoding(<<"v1:", value::binary>>, :escaped_v1), do: output(value, <<>>)
  defp decode_encoding(_value, :escaped_v1), do: error(:codec_error, :field_marker)
  defp decode_encoding(_value, _encoding), do: raise(ArgumentError, "unknown field encoding")

  defp decode_value(value, :bytes, _options), do: {:ok, value}

  defp decode_value(value, :string, _options) do
    if String.valid?(value), do: {:ok, value}, else: error(:invalid_encoding, :utf8)
  end

  defp decode_value("0", :boolean, _options), do: {:ok, false}
  defp decode_value("1", :boolean, _options), do: {:ok, true}
  defp decode_value(_value, :boolean, _options), do: error(:codec_error, :boolean)

  defp decode_value(value, :integer, options) do
    minimum = Keyword.get(options, :min)
    maximum = Keyword.get(options, :max)

    unless (is_nil(minimum) or is_integer(minimum)) and
             (is_nil(maximum) or is_integer(maximum)) do
      raise ArgumentError, "integer bounds must be integers"
    end

    case Integer.parse(value) do
      {number, ""} ->
        if (is_nil(minimum) or number >= minimum) and (is_nil(maximum) or number <= maximum),
          do: {:ok, number},
          else: error(:codec_error, :integer_range)

      _ ->
        error(:codec_error, :integer)
    end
  end

  defp decode_value(_value, _type, _options), do: raise(ArgumentError, "unknown field type")

  defp output(<<>>, decoded), do: {:ok, decoded}

  defp output(<<92, a, b, c, rest::binary>>, decoded)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7 do
    byte = (a - ?0) * 64 + (b - ?0) * 8 + c - ?0
    output(rest, <<decoded::binary, byte>>)
  end

  defp output(<<byte, rest::binary>>, decoded) when byte >= 32 and byte != 92 do
    output(rest, <<decoded::binary, byte>>)
  end

  defp output(_value, _reversed), do: error(:invalid_encoding, :output_escape)

  defp max_bytes(options) do
    case Keyword.get(options, :max_bytes, 1_048_576) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "max_bytes must be a positive integer"
    end
  end

  defp error(kind, reason) do
    {:error, %Error{kind: kind, phase: :capture, details: %{reason: reason}}}
  end
end
