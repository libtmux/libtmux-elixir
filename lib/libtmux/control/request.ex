defmodule LibTmux.Control.Request do
  @moduledoc """
  Data for the qualified control lane's supported commands.

  Field reads encode one named variable losslessly. Server user options accept
  literal binary values. Domain actions use the same lane for split, rename
  and literal/named input. Constructing a request performs no I/O; use
  `LibTmux.Control.execute/3` or retain a handle with `LibTmux.Control.submit/3`.
  The host must qualify hooks, aliases and mode-dependent input bindings along
  with other stream writers. Arbitrary commands, formats and raw control lines
  require separate qualification and are not accepted by this lane.
  """
  alias LibTmux.{Codec, Command, Error, Format, Ref}

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value, :target]

  @typedoc "Command data for the qualified lane; construction does not validate admission or perform I/O."
  @opaque t :: %__MODULE__{}

  @doc """
  Reads a named format variable, optionally from an exact instance-bound target.

  Existing empty fields succeed. A target that disappears before the read
  produces an acknowledged failed operation and leaves the connection usable.
  A reference does not reserve the object's lifetime.

  See the [worked example](managed-control.html).
  """
  @spec field(String.t(), Ref.t() | nil) :: t()
  def field(variable, target \\ nil),
    do: %__MODULE__{kind: :field, value: variable, target: target}

  @doc """
  Sets a server user option with an `@name` and a literal binary value.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec set_user_option(String.t(), binary()) :: t()
  def set_user_option(name, value),
    do: %__MODULE__{kind: :set_user_option, value: {name, value}}

  @doc false
  def action(kind, target, value, options),
    do: %__MODULE__{kind: :action, value: {kind, value, options}, target: target}

  @doc false
  def prepare(%__MODULE__{} = request, instance) do
    with {:ok, line} <- encode(request, instance),
         {:ok, request} <- LibTmux.Control.OwnedTerm.copy(request, 20_000),
         do: {:ok, request, line}
  end

  # Rebuilt at both publication boundaries; a struct is not a lane certificate.
  @doc false
  def encode(%__MODULE__{kind: :action, value: {kind, value, options}, target: target}, instance) do
    with {:ok, command} <-
           LibTmux.Action.command(kind, target, value, options, instance, :control) do
      {:ok, Command.render(command, max_bytes: 65_535) <> "\n"}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError] ->
      {:error, %Error{kind: :invalid_command, phase: :validation, certainty: :no_write}}
  end

  def encode(%__MODULE__{} = request, instance) do
    with :ok <- target(request, instance) do
      command =
        case request do
          %{kind: :field, value: variable} ->
            args = if request.target, do: ["-t", request.target.id], else: []

            Command.new(
              "display-message",
              ["-p" | args] ++ [field_format(variable, request.target)]
            )

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

  @doc """
  Checks a qualified request's reply shape; a tmux error reply remains a command outcome.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec verify_reply(t(), :ok | :error, [binary()]) :: :ok | {:error, Error.t()}
  def verify_reply(request, status, lines) do
    with {:ok, _status, _lines} <- normalize_reply(request, status, lines), do: :ok
  end

  @doc false
  @spec normalize_reply(t(), :ok | :error, [binary()]) ::
          {:ok, :ok | :error, [binary()]} | {:error, Error.t()}
  def normalize_reply(_request, :error, lines), do: {:ok, :error, lines}

  def normalize_reply(%{kind: :action, value: {:split, _, _}}, :ok, [id]) do
    case Ref.new(:pane, id, "reply") do
      {:ok, _ref} -> {:ok, :ok, [id]}
      _ -> invalid_reply()
    end
  end

  def normalize_reply(%{kind: :action, value: {kind, _, _}}, :ok, [])
      when kind in [:rename_session, :rename_window, :send_text, :send_keys],
      do: {:ok, :ok, []}

  def normalize_reply(%{kind: :field, target: %Ref{} = target}, :ok, [<<"t1:", rest::binary>>]) do
    case :binary.split(rest, ":") do
      [resolved, field] ->
        with :ok <- validate_field(field) do
          cond do
            resolved == target.id -> {:ok, :ok, [field]}
            resolved == "" -> {:ok, :error, ["can't find #{target.entity}: #{target.id}"]}
            true -> invalid_reply()
          end
        end

      _ ->
        invalid_reply()
    end
  end

  def normalize_reply(%{kind: :field, target: nil}, :ok, [field]) do
    with :ok <- validate_field(field), do: {:ok, :ok, [field]}
  end

  def normalize_reply(%{kind: :set_user_option}, :ok, []), do: {:ok, :ok, []}
  def normalize_reply(_request, _status, _lines), do: invalid_reply()

  defp invalid_reply,
    do: {:error, %Error{kind: :invalid_reply, phase: :parse, certainty: :unknown}}

  defp validate_field(field) do
    case Codec.decode_field(field <> "\n", :bytes, encoding: :escaped_v1) do
      {:ok, _value} -> :ok
      error -> error
    end
  end

  defp field_format(variable, nil), do: Format.field(variable)

  # display-message permits an unresolved target; qualify identity and value together.
  defp field_format(variable, %Ref{entity: entity}) do
    identity =
      case entity do
        :session -> "session_id"
        :window -> "window_id"
        :pane -> "pane_id"
      end

    "t1:" <> ~S"#{" <> identity <> "}:" <> Format.field(variable)
  end

  defp target(%{kind: :field, target: nil}, _instance), do: :ok
  defp target(%{kind: :set_user_option, target: nil}, _instance), do: :ok

  defp target(%{kind: :field, target: %Ref{entity: entity} = ref}, instance)
       when entity in [:session, :window, :pane], do: Ref.validate(ref, instance)

  defp target(_request, _instance),
    do: {:error, %Error{kind: :invalid_target, certainty: :no_write}}
end
