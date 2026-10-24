defmodule LibTmux.Deadline do
  @moduledoc """
  A node-local monotonic deadline shared by every stage of an operation.

  Construct it once at admission. Passing it between stages preserves the
  original budget; it is not a portable timestamp or a wire value.
  """

  @enforce_keys [:expires_at]
  defstruct [:expires_at]

  @typedoc "A node-local monotonic millisecond cutoff. Share it between stages; never serialize it as a portable deadline."
  @opaque t :: %__MODULE__{expires_at: integer()}
  @typedoc "An optional node-local monotonic clock sample in milliseconds, used instead of sampling the current clock."
  @type option :: {:now, integer()}

  @doc """
  Creates a deadline from a positive millisecond budget.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec new(pos_integer(), [option()]) :: t()
  def new(milliseconds, options \\ [])

  def new(milliseconds, options) when is_integer(milliseconds) and milliseconds > 0 do
    %__MODULE__{expires_at: now(options) + milliseconds}
  end

  def new(_milliseconds, _options) do
    raise ArgumentError, "timeout must be a positive integer in milliseconds"
  end

  @doc """
  Returns the remaining milliseconds, clamped to zero after expiry.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec remaining(t(), [option()]) :: non_neg_integer()
  def remaining(%__MODULE__{expires_at: expires_at}, options \\ []) do
    max(expires_at - now(options), 0)
  end

  defp now(options) do
    Keyword.get_lazy(options, :now, fn -> System.monotonic_time(:millisecond) end)
  end
end
