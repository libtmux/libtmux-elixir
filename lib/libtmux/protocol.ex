defmodule LibTmux.Protocol do
  @moduledoc """
  Assembles bounded control-mode replies and lexical notifications from bytes.

  Reply guards retain timestamp, command number and flags. Inside a block,
  notification-looking output stays data. The parser cannot authenticate
  injected matching guards: shared lanes must separately qualify commands,
  hooks and subscription expansion. Notification payloads need semantic
  validation before they can update a graph.

  A parse error retains already completed events in `error.details.events`.
  Its owner must retire the lane rather than reuse the rejected state.
  """

  alias LibTmux.Error

  @limits %{
    max_chunk_bytes: 65_536,
    max_line_bytes: 65_536,
    max_frame_bytes: 262_144,
    max_frame_lines: 4096,
    max_events: 1024
  }

  @notifications %{
    "client-detached" => :client_detached,
    "client-session-changed" => :client_session_changed,
    "config-error" => :config_error,
    "continue" => :continue,
    "exit" => :exit,
    "extended-output" => :extended_output,
    "layout-change" => :layout_change,
    "message" => :message,
    "output" => :output,
    "pane-mode-changed" => :pane_mode_changed,
    "pause" => :pause,
    "session-changed" => :session_changed,
    "session-renamed" => :session_renamed,
    "session-window-changed" => :session_window_changed,
    "sessions-changed" => :sessions_changed,
    "subscription-changed" => :subscription_changed,
    "unlinked-window-add" => :unlinked_window_add,
    "unlinked-window-close" => :unlinked_window_close,
    "unlinked-window-renamed" => :unlinked_window_renamed,
    "window-add" => :window_add,
    "window-close" => :window_close,
    "window-pane-changed" => :window_pane_changed,
    "window-renamed" => :window_renamed
  }

  defstruct carry: "", guard: nil, lines: [], frame_bytes: 0, frame_lines: 0, limits: @limits

  @typedoc "A complete tmux reply guard: timestamp, command number and flags, retained for correlation."
  @type guard_id :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @typedoc "A framed reply or lexical notification. Payloads still require semantic validation before graph updates."
  @type event ::
          {:reply, :ok | :error, guard_id(), [binary()]}
          | {:notification, atom(), binary()}
          | {:unknown, binary()}
  @typedoc "Immutable parser carry and bounded in-flight frame state; discard it after any parse error."
  @opaque t :: %__MODULE__{}
  @typedoc "A positive parser ceiling, measured in bytes, lines or emitted events as named."
  @type option ::
          {:max_chunk_bytes | :max_line_bytes | :max_frame_bytes | :max_frame_lines | :max_events,
           pos_integer()}

  @doc "Constructs a parser with positive byte, line and event limits."
  @spec new([option()]) :: t()
  def new(options \\ []) do
    limits = options |> Keyword.validate!(Map.to_list(@limits)) |> Map.new()

    Enum.each(limits, fn {key, value} ->
      unless is_integer(value) and value > 0,
        do: raise(ArgumentError, "#{key} must be a positive integer")
    end)

    %__MODULE__{limits: limits}
  end

  @doc "Consumes one byte chunk without performing I/O."
  @spec feed(t(), binary()) :: {:ok, [event()], t()} | {:error, Error.t()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    if byte_size(chunk) > state.limits.max_chunk_bytes do
      error(:resource_limit, :chunk_bytes, [])
    else
      parse(%{state | carry: ""}, state.carry <> chunk, [], 0)
    end
  end

  @doc "Rejects a stream ending inside a line or reply block."
  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{carry: "", guard: nil}), do: :ok
  def finish(%__MODULE__{}), do: error(:protocol_error, :truncated_stream, [])

  defp parse(state, buffer, events, count) do
    case :binary.match(buffer, "\n") do
      :nomatch ->
        if byte_size(buffer) > state.limits.max_line_bytes,
          do: error(:resource_limit, :line_bytes, events),
          else: {:ok, Enum.reverse(events), %{state | carry: :binary.copy(buffer)}}

      {size, 1} ->
        if size > state.limits.max_line_bytes do
          error(:resource_limit, :line_bytes, events)
        else
          <<line::binary-size(^size), 10, rest::binary>> = buffer

          case line(state, line) do
            {:ok, next, nil} ->
              parse(next, rest, events, count)

            {:ok, _next, _event} when count >= state.limits.max_events ->
              error(:resource_limit, :events, events)

            {:ok, next, event} ->
              parse(next, rest, [event | events], count + 1)

            {:error, kind, reason} ->
              error(kind, reason, events)
          end
        end
    end
  end

  defp line(%{guard: nil} = state, line) do
    case guard(line) do
      {:ok, "%begin", id} ->
        {:ok, %{state | guard: id}, nil}

      {:ok, _end, _id} ->
        {:error, :protocol_error, :unexpected_guard}

      :invalid ->
        {:error, :protocol_error, :invalid_guard}

      :none ->
        {:ok, state, notification(line)}
    end
  end

  defp line(state, line) do
    case guard(line) do
      {:ok, kind, id} when kind in ["%end", "%error"] and id == state.guard ->
        status = if kind == "%end", do: :ok, else: :error
        event = {:reply, status, id, Enum.reverse(state.lines)}
        {:ok, %{state | guard: nil, lines: [], frame_bytes: 0, frame_lines: 0}, event}

      _ ->
        bytes = state.frame_bytes + byte_size(line) + 1
        lines = state.frame_lines + 1

        if bytes > state.limits.max_frame_bytes or lines > state.limits.max_frame_lines do
          {:error, :resource_limit, :frame_size}
        else
          {:ok,
           %{
             state
             | lines: [:binary.copy(line) | state.lines],
               frame_bytes: bytes,
               frame_lines: lines
           }, nil}
        end
    end
  end

  defp guard(line) do
    case :binary.split(line, " ") do
      [kind, rest] when kind in ["%begin", "%end", "%error"] and byte_size(rest) <= 62 ->
        guard_values(kind, rest)

      [kind | _] when kind in ["%begin", "%end", "%error"] ->
        :invalid

      _ ->
        :none
    end
  end

  defp guard_values(kind, rest) do
    case :binary.split(rest, " ", [:global]) do
      [time, number, flags] ->
        with {:ok, time} <- unsigned(time),
             {:ok, number} <- unsigned(number),
             {:ok, flags} <- unsigned(flags) do
          {:ok, kind, {time, number, flags}}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp unsigned(value) when byte_size(value) in 1..20 do
    if Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9)),
      do: {:ok, String.to_integer(value)},
      else: :invalid
  end

  defp unsigned(_value), do: :invalid

  defp notification(<<"%", body::binary>> = raw) do
    [name | rest] = :binary.split(body, " ")

    case Map.fetch(@notifications, name) do
      {:ok, name} -> {:notification, name, Enum.at(rest, 0, "") |> :binary.copy()}
      :error -> {:unknown, :binary.copy(raw)}
    end
  end

  defp notification(raw), do: {:unknown, :binary.copy(raw)}

  defp error(kind, reason, events) do
    {:error,
     %Error{
       kind: kind,
       phase: :parse,
       path: [:control],
       details: %{reason: reason, events: Enum.reverse(events)}
     }}
  end
end
