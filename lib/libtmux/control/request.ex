defmodule LibTmux.Control.Request do
  @moduledoc false
  alias LibTmux.{Codec, Command, Error, Format, Ref}

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value, :target]

  def field(variable, target \\ nil),
    do: %__MODULE__{kind: :field, value: variable, target: target}

  def set_user_option(name, value),
    do: %__MODULE__{kind: :set_user_option, value: {name, value}}

  # Rebuilt at both publication boundaries; a struct is not a lane certificate.
  def encode(%__MODULE__{} = request, instance) do
    with :ok <- target(request, instance) do
      command =
        case request do
          %{kind: :field, value: variable} ->
            args = if request.target, do: ["-t", request.target.id], else: []
            Command.new("display-message", ["-p" | args] ++ [Format.field(variable)])

          %{kind: :set_user_option, value: {name, value}}
          when is_binary(name) and byte_size(name) in 2..64 and is_binary(value) and
                 byte_size(value) <= 16_000 ->
            unless Regex.match?(~r/\A@[a-zA-Z][a-zA-Z0-9_]*\z/, name),
              do: raise(ArgumentError, "invalid user option")

            Command.new("set-option", ["-s", name, value])

          _ ->
            raise ArgumentError, "request is outside the qualified command lane"
        end

      line = Command.render(command, max_bytes: 65_535) <> "\n"
      {:ok, line}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError] ->
      {:error, %Error{kind: :invalid_command, phase: :validation, certainty: :no_write}}
  end

  def verify_reply(_request, :error, _lines), do: :ok

  def verify_reply(%{kind: :field}, :ok, [field]) do
    case Codec.decode_field(field <> "\n", :bytes, encoding: :escaped_v1) do
      {:ok, _value} -> :ok
      error -> error
    end
  end

  def verify_reply(%{kind: :set_user_option}, :ok, []), do: :ok

  def verify_reply(_request, _status, _lines),
    do: {:error, %Error{kind: :invalid_reply, phase: :parse, certainty: :unknown}}

  defp target(%{kind: :field, target: nil}, _instance), do: :ok
  defp target(%{kind: :set_user_option, target: nil}, _instance), do: :ok

  defp target(%{kind: :field, target: %Ref{entity: entity} = ref}, instance)
       when entity in [:session, :window, :pane], do: Ref.validate(ref, instance)

  defp target(_request, _instance),
    do: {:error, %Error{kind: :invalid_target, certainty: :no_write}}
end
