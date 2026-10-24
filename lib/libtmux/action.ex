defmodule LibTmux.Action do
  @moduledoc """
  Shared results for explicit pane, window and session actions.

  Pass a `LibTmux.Server` for one-shot execution or a `LibTmux.Control` for
  managed execution in its qualified connection. No action changes transport,
  replays a mutation or refreshes an observation. One-shot actions check the
  server incarnation before execution; that check leaves a check/use race.

  Completed, failed, skipped and unknown outcomes remain values, including
  from bang functions. `value` is populated only for a completed command.
  `details` retains the transport's original bounded evidence. Acknowledgement
  does not prove that a program processed input or finished running.
  API errors use `LibTmux.Error`; admitted control errors preserve the recovery
  handle in `LibTmux.Control.ExecutionError`.

  A nonzero one-shot client exit reports `:failed` with `:observed` certainty:
  its exit status is observed, not an authenticated tmux command reply or
  proof that no effects occurred.

  Optional session context checks physical membership at tmux's command
  resolution. It does not bind a particular WindowLink index when a window
  has multiple links in that session. WindowLink references are rejected.
  See `LibTmux.Pane.split/3`, `LibTmux.Pane.send_text/4` and
  `LibTmux.Window.rename/4` for caller examples.
  """
  alias LibTmux.{Codec, Command, Control, Deadline, Error, Format, ProcessIdentity, Ref, Server}
  alias LibTmux.Control.Request

  @typedoc "Explicitly selected one-shot descriptor or pinned qualified connection."
  @type connection :: Server.t() | Control.t()
  @typedoc "A 1..600000ms execution budget, default 5000ms; optional exact session context for physical targets."
  @type option :: {:timeout, 1..600_000} | {:session, Ref.t()}
  @typedoc "Canonical command outcome and original transport evidence; value exists only after acknowledged completion."
  @type result(value) :: %{
          outcome: :completed | :failed | :skipped | :unknown,
          certainty: Error.certainty(),
          evidence: atom(),
          transport: :one_shot | :control,
          value: value | nil,
          details: map()
        }
  @typedoc "An API refusal or a managed execution error retaining its recovery context."
  @type error :: Error.t() | LibTmux.Control.ExecutionError.t()

  @keys ~w(Enter Space Tab BTab BSpace Escape Up Down Left Right Home End PageUp PageDown Insert Delete)
  @modified_keys ~w(Up Down Left Right Home End PageUp PageDown Insert Delete)

  @doc false
  def run(:capture, %Control{}, _target, _value, _options), do: failure(:unsupported_transport)

  def run(kind, connection, %Ref{} = target, value, options) do
    entered_at = System.monotonic_time(:millisecond)
    lane = if match?(%Control{}, connection), do: :control, else: :one_shot

    with {:ok, deadline, options} <- prepare_options(options, entered_at),
         {:ok, command} <- command(kind, target, value, options, target.server_instance, lane) do
      case connection do
        %Control{} ->
          request = Request.action(kind, target, value, options)

          with {:ok, result} <- Control.execute_deadline(connection, request, deadline),
               do: {:ok, result(result, :control, action_value(kind, result))}

        %Server{} ->
          with :ok <- identify(connection, target, deadline) do
            execute(connection, kind, command, options, deadline)
          end
      end
    end
  end

  def run(_kind, _connection, _target, _value, _options), do: failure(:invalid_target)

  @doc false
  def unwrap({:ok, result}), do: result
  def unwrap({:error, error}), do: raise(error)

  defp prepare_options(options, entered_at) do
    if length(options) != map_size(Map.new(options)),
      do: raise(ArgumentError, "duplicate options")

    {timeout, options} = Keyword.pop(options, :timeout, 5000)

    unless is_integer(timeout) and timeout in 1..600_000,
      do: raise(ArgumentError, "timeout must be 1..600000ms")

    {:ok, Deadline.new(timeout, now: entered_at), options}
  rescue
    ArgumentError -> failure(:invalid_command)
  end

  @doc false
  def command(kind, %Ref{} = target, value, options, instance, lane) do
    options = Keyword.validate!(options, defaults(kind))

    with :ok <- target(kind, target, instance),
         :ok <- session(options[:session], instance),
         :ok <- lane(kind, value, lane) do
      {:ok, build(kind, target, value, options)}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError] -> failure(:invalid_command)
  end

  defp defaults(:split),
    do: [
      session: nil,
      axis: :vertical,
      size: nil,
      before: false,
      detached: true,
      cwd: nil,
      command: []
    ]

  defp defaults(:capture),
    do: [session: nil, start_line: 0, end_line: :last, join_lines: false, max_bytes: 65_536]

  defp defaults(kind) when kind in [:rename_session, :rename_window, :send_text, :send_keys],
    do: [session: nil]

  defp target(kind, %Ref{entity: entity} = target, instance) do
    expected =
      case kind do
        :rename_session -> :session
        :rename_window -> :window
        kind when kind in [:split, :send_text, :send_keys, :capture] -> :pane
      end

    if expected == entity, do: Ref.validate(target, instance), else: failure(:invalid_target)
  end

  defp session(nil, _instance), do: :ok
  defp session(%Ref{entity: :session} = session, instance), do: Ref.validate(session, instance)
  defp session(_session, _instance), do: failure(:invalid_target)

  defp lane(:capture, _value, :control), do: failure(:unsupported_transport)

  defp lane(_kind, _value, _lane), do: :ok

  defp target_string(%Ref{entity: :session, id: id}, nil), do: id
  defp target_string(%Ref{entity: :pane, id: id}, %Ref{id: session}), do: session <> ":." <> id
  defp target_string(%Ref{entity: :window, id: id}, %Ref{id: session}), do: session <> ":" <> id
  defp target_string(%Ref{id: id}, nil), do: id

  defp build(kind, target, name, options) when kind in [:rename_session, :rename_window] do
    unless is_binary(name) and byte_size(name) in 1..1024 and String.valid?(name) and
             not Regex.match?(~r/\p{Cc}/u, name),
           do:
             raise(
               ArgumentError,
               "rename requires 1..1024 UTF-8 bytes without control characters"
             )

    command = if kind == :rename_session, do: "rename-session", else: "rename-window"

    Command.new(command, [
      "-t",
      target_string(target, options[:session]),
      "--",
      Format.literal(name)
    ])
  end

  defp build(:split, target, _value, options) do
    axis =
      case options[:axis] do
        :horizontal -> "-h"
        :vertical -> "-v"
        _ -> raise ArgumentError, "split axis must be horizontal or vertical"
      end

    size =
      case options[:size] do
        nil -> []
        {:percent, n} when is_integer(n) and n in 1..99 -> ["-l", "#{n}%"]
        {:cells, n} when is_integer(n) and n in 1..32_767 -> ["-l", Integer.to_string(n)]
        _ -> raise ArgumentError, "split size requires positive cells or 1..99 percent"
      end

    cwd = if is_nil(options[:cwd]), do: [], else: ["-c", Format.literal(options[:cwd])]
    argv = options[:command]

    unless is_list(argv) and length(argv) <= 64,
      do: raise(ArgumentError, "split requires at most 64 command arguments")

    args =
      ["-t", target_string(target, options[:session]), "-P", "-F", ~S"#{pane_id}", axis] ++
        flag(options[:detached], "-d") ++
        flag(options[:before], "-b") ++ size ++ cwd ++ ["--" | argv]

    Command.new("split-window", args)
  end

  defp build(:send_text, target, bytes, options)
       when is_binary(bytes) and byte_size(bytes) <= 1020 do
    # Hex keys preserve individual bytes, including NUL and invalid UTF-8.
    encoded = for <<byte <- bytes>>, do: Integer.to_string(byte, 16)
    args = ["-H", "-t", target_string(target, options[:session]), "--" | encoded]
    # Empty key lists would resend tmux's triggering key rather than send nothing.
    Command.new("send-keys", if(encoded == [], do: args ++ [""], else: args))
  end

  defp build(:send_keys, target, keys, options) when is_list(keys) do
    unless length(keys) in 1..128 and Enum.all?(keys, &key?/1),
      do: raise(ArgumentError, "send_keys requires 1..128 supported key names")

    Command.new("send-keys", ["-t", target_string(target, options[:session]), "--" | keys])
  end

  defp build(:capture, target, _value, options) do
    unless is_integer(options[:max_bytes]) and options[:max_bytes] in 0..1_048_576,
      do: raise(ArgumentError, "capture max_bytes must be 0..1048576")

    unless is_integer(options[:start_line]) and options[:start_line] in -32_768..32_767,
      do: raise(ArgumentError, "capture start_line must be -32768..32767")

    args =
      [
        "-p",
        "-t",
        target_string(target, options[:session]),
        "-S",
        line(options[:start_line]),
        "-E",
        line(options[:end_line])
      ] ++ flag(options[:join_lines], "-J")

    Command.new("capture-pane", args)
  end

  defp line(:last), do: "-"
  defp line(n) when is_integer(n) and n in -32_768..32_767, do: Integer.to_string(n)
  defp flag(true, flag), do: [flag]
  defp flag(false, _flag), do: []

  defp key?(key) when is_binary(key) and byte_size(key) <= 32 do
    case Regex.run(~r/\A((?:(?:C|M|S)-){0,3})(.+)\z/, key) do
      [_, prefixes, base] ->
        modifiers = String.split(prefixes, "-", trim: true)

        function_key = Regex.match?(~r/\AF(?:[1-9]|1[0-2])\z/, base)

        Enum.uniq(modifiers) == modifiers and
          cond do
            modifiers == [] -> base in @keys or function_key
            modifiers == ["C"] and Regex.match?(~r/\A[a-z@\[\\\]\^_? ]\z/, base) -> true
            modifiers == ["M"] and byte_size(base) == 1 and base >= " " and base <= "~" -> true
            true -> base in @modified_keys or function_key
          end

      _ ->
        false
    end
  end

  defp key?(_key), do: false

  defp identify(server, target, deadline) do
    with {:ok, output} <-
           Server.run(server, Command.new("display-message", ["-p", ~S"#{pid}"]),
             deadline: deadline,
             max_stdout_bytes: 64
           ),
         {:ok, pid} <- Codec.decode_field(output.stdout, :integer, min: 1, max: 2_147_483_647),
         {:ok, instance} <- ProcessIdentity.read(pid),
         :ok <- Ref.validate(target, instance) do
      :ok
    else
      {:error, error} -> {:error, %{error | certainty: :no_write}}
    end
  end

  defp execute(server, kind, command, options, deadline) do
    limit = if kind == :capture, do: Keyword.get(options, :max_bytes, 65_536), else: 65_536

    case Server.run(server, command, deadline: deadline, max_stdout_bytes: limit) do
      {:ok, output} ->
        case decode(kind, output.stdout) do
          {:ok, value} ->
            {:ok,
             result(
               Map.merge(output, %{
                 outcome: :completed,
                 certainty: :acknowledged,
                 evidence: :process_exit
               }),
               :one_shot,
               value
             )}

          {:error, error} ->
            {:error, %{error | details: output}}
        end

      {:error, %Error{kind: :command_error, details: output}} ->
        {:ok,
         result(
           Map.merge(output, %{
             outcome: :failed,
             certainty: :observed,
             evidence: :process_exit
           }),
           :one_shot,
           nil
         )}

      error ->
        error
    end
  end

  defp decode(:capture, bytes), do: {:ok, bytes}

  defp decode(:split, bytes) do
    case :binary.split(bytes, "\n") do
      [id, ""] ->
        case Ref.new(:pane, id, "reply") do
          {:ok, _ref} -> {:ok, id}
          _ -> invalid_reply()
        end

      _ ->
        invalid_reply()
    end
  end

  defp decode(_kind, ""), do: {:ok, :ok}
  defp decode(_kind, _bytes), do: invalid_reply()

  defp action_value(:split, %{outcome: :completed, lines: [id]}), do: id
  defp action_value(_kind, %{outcome: :completed}), do: :ok
  defp action_value(_kind, _result), do: nil

  defp result(result, lane, value),
    do: %{
      outcome: result.outcome,
      certainty: result.certainty,
      evidence: result.evidence,
      transport: lane,
      value: value,
      details: result
    }

  defp failure(kind), do: {:error, %Error{kind: kind, phase: :validation, certainty: :no_write}}

  defp invalid_reply,
    do: {:error, %Error{kind: :invalid_reply, phase: :parse, certainty: :acknowledged}}
end
