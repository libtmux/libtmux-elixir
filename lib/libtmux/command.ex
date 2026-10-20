defmodule LibTmux.Command do
  @moduledoc """
  A command value with separate argv and tmux-text renderers.

  Construction performs no I/O. Arguments are bytes without NUL. Rendering
  protects command syntax; arguments interpreted as formats still require
  `LibTmux.Format`. A command value does not authorize a shared control lane
  or establish completion behavior, including configured hooks and aliases.
  """

  @enforce_keys [:name, :args]
  defstruct [:name, :args]

  @opaque t :: %__MODULE__{name: String.t(), args: [binary()]}

  @doc "Constructs a trusted command, rejecting invalid arguments and input size."
  @spec new(String.t(), [binary()], keyword()) :: t()
  def new(name, args, options \\ []) do
    limit = limit(options)

    unless is_binary(name) and byte_size(name) in 1..64 and
             Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_-]*\z/, name) and is_list(args) and
             length(args) <= 1024 and Enum.all?(args, &argument?/1) do
      raise ArgumentError,
            "command requires a valid name and at most 1024 NUL-free binary arguments"
    end

    ensure_size!([name | args], limit)
    %__MODULE__{name: name, args: args}
  end

  @doc "Returns process arguments, preserving terminal semicolons in tmux's argv parser."
  @spec argv(t(), keyword()) :: [binary()]
  def argv(%__MODULE__{name: name, args: args}, options \\ []) do
    _ = new(name, args, options)
    result = [name | Enum.map(args, &argv_argument/1)]
    ensure_size!(result, limit(options))
    result
  end

  @doc "Renders one newline-free tmux command line within its encoded byte budget."
  @spec render(t(), keyword()) :: binary()
  def render(%__MODULE__{name: name, args: args}, options \\ []) do
    _ = new(name, args, options)

    size =
      byte_size(name) +
        Enum.reduce(args, 0, fn value, size -> size + 3 + 4 * byte_size(value) end)

    if size > limit(options), do: raise(ArgumentError, "encoded command exceeds max_bytes")

    [name | Enum.map(args, fn value -> [" ", quote_argument(value)] end)]
    |> IO.iodata_to_binary()
  end

  defp quote_argument(value) do
    [
      "\"",
      for(<<byte <- value>>,
        do: ["\\", byte |> Integer.to_string(8) |> String.pad_leading(3, "0")]
      ),
      "\""
    ]
  end

  defp argv_argument(value) do
    if byte_size(value) > 0 and :binary.last(value) == ?; do
      binary_part(value, 0, byte_size(value) - 1) <> "\\;"
    else
      value
    end
  end

  defp argument?(value), do: is_binary(value) and :binary.match(value, <<0>>) == :nomatch

  defp ensure_size!(arguments, limit) do
    size = Enum.reduce(arguments, 0, fn argument, size -> size + byte_size(argument) + 1 end)
    if size > limit, do: raise(ArgumentError, "command exceeds max_bytes")
  end

  defp limit(options) do
    case Keyword.get(options, :max_bytes, 65_536) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "max_bytes must be a positive integer"
    end
  end
end
