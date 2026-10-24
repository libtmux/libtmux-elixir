defmodule LibTmux.Ref do
  @moduledoc """
  An exact observed target bound to one server instance.

  A window-link ID is its observed `{session_id, index, window_id}` binding,
  not a unique lifetime identifier. Validation detects known stale instances;
  it does not reserve an object or close a one-shot check/use race.
  """

  alias LibTmux.{Client, Error, Pane, Schema, Session, Window, WindowLink}

  @enforce_keys [:entity, :id, :server_instance]
  defstruct [:entity, :id, :server_instance]

  @typedoc "The target kind; physical windows and session-relative links have different identities."
  @type entity :: :session | :window | :pane | :window_link | :client
  @typedoc "A native ID or observed session/index/window link binding; neither reserves an object's lifetime."
  @type id :: String.t() | {String.t(), non_neg_integer(), String.t()}
  @typedoc "An exact observed identity bound to a tmux server incarnation, separate from a connection epoch."
  @type t :: %__MODULE__{entity: entity(), id: id(), server_instance: String.t()}

  @doc """
  Validates a native identity and binds it to a nonempty instance token.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec new(entity(), id(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(entity, id, instance) do
    if valid_id?(entity, id) and valid_token?(instance) do
      {:ok, %__MODULE__{entity: entity, id: id, server_instance: instance}}
    else
      {:error, %Error{kind: :invalid_target, certainty: :no_write, path: [:target]}}
    end
  end

  @doc """
  Builds a reference from an observation's own identity and server instance.

  Validates the identity with `new/3` without I/O or a fresh observation.
  Malformed identities and other inputs return an `:invalid_target` error.
  Other captured fields may remain unloaded or unavailable. A reference does
  not prove that its target still exists. Window links retain their tuple
  binding and lifetime limitation; domain actions reject window-link refs.

  ## Examples

      iex> pane = %LibTmux.Pane{id: "%7", server_instance: "instance-a"}
      iex> {:ok, ref} = LibTmux.Ref.from_observation(pane)
      iex> {ref.entity, ref.id, ref.server_instance}
      {:pane, "%7", "instance-a"}
  """
  @spec from_observation(Schema.observation()) :: {:ok, t()} | {:error, Error.t()}
  def from_observation(%Session{id: id, server_instance: instance}),
    do: new(:session, id, instance)

  def from_observation(%Window{id: id, server_instance: instance}),
    do: new(:window, id, instance)

  def from_observation(%WindowLink{id: id, server_instance: instance}),
    do: new(:window_link, id, instance)

  def from_observation(%Pane{id: id, server_instance: instance}),
    do: new(:pane, id, instance)

  def from_observation(%Client{id: id, server_instance: instance}),
    do: new(:client, id, instance)

  def from_observation(_observation),
    do: {:error, %Error{kind: :invalid_target, certainty: :no_write, path: [:target]}}

  @doc """
  Rejects malformed references and known server-instance mismatches.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec validate(t(), String.t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = ref, instance) do
    case new(ref.entity, ref.id, ref.server_instance) do
      {:ok, _} when ref.server_instance == instance ->
        :ok

      {:ok, _} ->
        {:error, %Error{kind: :stale_target, certainty: :no_write, path: [:target]}}

      {:error, _} = error ->
        error
    end
  end

  defp valid_id?(:session, id), do: numbered_id?(id, ?$)
  defp valid_id?(:window, id), do: numbered_id?(id, ?@)
  defp valid_id?(:pane, id), do: numbered_id?(id, ?%)
  defp valid_id?(:client, id), do: valid_token?(id)

  defp valid_id?(:window_link, {session, index, window}) do
    numbered_id?(session, ?$) and is_integer(index) and index >= 0 and numbered_id?(window, ?@)
  end

  defp valid_id?(_entity, _id), do: false

  defp numbered_id?(<<prefix, digits::binary>>, prefix) when byte_size(digits) in 1..20 do
    case Integer.parse(digits) do
      {number, ""} when number >= 0 -> Integer.to_string(number) == digits
      _ -> false
    end
  end

  defp numbered_id?(_id, _prefix), do: false

  defp valid_token?(value) when is_binary(value) and byte_size(value) in 1..256 do
    String.valid?(value) and :binary.match(value, [<<0>>, "\n", "\r"]) == :nomatch
  end

  defp valid_token?(_value), do: false
end
