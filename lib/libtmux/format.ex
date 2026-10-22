defmodule LibTmux.Format do
  @moduledoc """
  Constructs literal operands for tmux formats without evaluating their text.

  Command quoting and format quoting are separate. A literal may contain
  newlines or arbitrary non-NUL bytes; this does not qualify its output for
  a shared line-oriented control lane.
  """

  @syntax_bytes [35, 123, 125, 44, 58, 59]

  @field_modifiers Enum.map_join([92, 36 | Enum.to_list(1..31) ++ [127]], ";", fn byte ->
                     pattern =
                       case byte do
                         92 -> "\\\\"
                         36 -> "\\$"
                         _ -> <<byte>>
                       end

                     replacement =
                       "\\\\" <> (byte |> Integer.to_string(8) |> String.pad_leading(3, "0"))

                     "s|" <> pattern <> "|" <> replacement <> "|"
                   end)

  @doc """
  Encodes one named field for `LibTmux.Codec.decode_field/3` with `encoding: :escaped_v1`.

  Backslashes are replaced first, then dollars and ASCII control bytes.
  This protects values from tmux 3.4's ambiguous print escaping. The `v1:`
  prefix and encoded newlines prevent field text from becoming reply guards.
  This is one field per response, not a delimiter-framed row or arbitrary
  format wrapper. The caller must still bound the response and validate the
  field against its schema and the connected server's capabilities.
  """
  @spec field(String.t()) :: binary()
  def field(name) when is_binary(name) do
    unless byte_size(name) in 1..64 and Regex.match?(~r/\A@?[a-zA-Z][a-zA-Z0-9_]*\z/, name),
      do: raise(ArgumentError, "field must be a tmux variable or named user option")

    "v1:" <> ~S"#{" <> @field_modifiers <> ":" <> name <> "}"
  end

  @doc "Returns a format expression that expands to exactly the supplied non-NUL bytes."
  @spec literal(binary()) :: binary()
  def literal(value) when is_binary(value) do
    if :binary.match(value, <<0>>) != :nomatch do
      raise ArgumentError, "tmux format literals cannot contain NUL"
    end

    for <<byte <- value>>, into: "" do
      if byte in @syntax_bytes do
        ~S"#{a:" <> Integer.to_string(byte) <> "}"
      else
        <<byte>>
      end
    end
  end
end
