defmodule LibTmux.Transport.OneShot do
  @moduledoc """
  Executes one explicitly selected executable with bounded captured output.

  This Linux transport owns a native helper and its ordinary finite process
  tree. It never uses a shell. A worker owns the Port and observes caller
  death; the helper detects pipe closure after worker or VM death.
  Target environment entries travel as bytes to child `execve`, preserving
  empty values. The helper inherits the trusted host environment; requested
  target variables do not configure the helper. `TMUX` and `TMUX_PANE` are
  removed from the target environment.

  Limits apply per call: stdout defaults to 1 MiB, stderr to 64 KiB, and
  retained chunks to 4096. `max_total_bytes` additionally bounds both streams
  together; it defaults to their summed limits. Overload returns an error
  with a bounded prefix.
  Independent caller processes require admission limits at their host or
  server boundary; this primitive maintains no shared request queue.

  A positive timeout becomes one execution deadline. Retirement can take
  up to a separate 750 ms cleanup allowance after expiry. Missing retirement
  proof remains `:unknown`. No result authorizes replay. Helper SIGKILL,
  hostile escape and uninterruptible kernel tasks are outside the ordinary
  tree guarantee. Building the native helper requires a C11 compiler.
  """

  alias LibTmux.{Deadline, Error}
  alias LibTmux.Transport.Native
  alias LibTmux.Transport.Native.Protocol, as: NativeProtocol

  @typedoc "Captured bytes and child exit status after proven owned-process retirement; nonzero exit remains a transport result."
  @type result :: %{
          stdout: binary(),
          stderr: binary(),
          exit_status: non_neg_integer(),
          cleanup: :retired
        }

  @typedoc """
  Per-call input and capture limits; bytes and chunks are bounded independently.

  Timeout and deadline are exclusive. A supplied deadline must have at most
  600,000 ms remaining at validation; it preserves its original cutoff.
  """
  @type option ::
          {:timeout, 1..600_000}
          | {:deadline, Deadline.t()}
          | {:cwd, String.t()}
          | {:env, %{optional(binary()) => binary()}}
          | {:max_stdout_bytes | :max_stderr_bytes, 0..16_777_216}
          | {:max_total_bytes, nil | 0..33_554_432}
          | {:max_chunks, 1..65_536}

  @cleanup_ms 750
  @chunk_bytes 8192

  @doc """
  Runs argv without a shell, retaining exit status separately from stdout and stderr.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec run(binary(), [binary()], [option()]) :: {:ok, result()} | {:error, Error.t()}
  def run(executable, arguments, options \\ []) do
    if length(options) != map_size(Map.new(options)),
      do: raise(ArgumentError, "duplicate transport options")

    if Keyword.has_key?(options, :deadline) and Keyword.has_key?(options, :timeout),
      do: raise(ArgumentError, "pass a deadline or timeout, not both")

    deadline =
      Keyword.get_lazy(options, :deadline, fn ->
        Deadline.new(Keyword.get(options, :timeout, 5000))
      end)

    options =
      Keyword.validate!(options, [
        :deadline,
        :env,
        :timeout,
        cwd: File.cwd!(),
        max_stdout_bytes: 1_048_576,
        max_stderr_bytes: 65_536,
        max_total_bytes: nil,
        max_chunks: 4096
      ])

    spec = validate(executable, arguments, options, deadline)

    if :os.type() == {:unix, :linux},
      do: run_worker(spec),
      else: {:error, %Error{kind: :unsupported_platform, phase: :spawn, certainty: :no_write}}
  end

  @doc """
  Runs argv, raising the same structured transport error on failure.

  See the [worked example](api-examples.html#encoding-and-protocol).
  """
  @spec run!(binary(), [binary()], [option()]) :: result()
  def run!(executable, arguments, options \\ []) do
    case run(executable, arguments, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp validate(executable, arguments, options, %Deadline{} = deadline) do
    limits = %{1 => options[:max_stdout_bytes], 2 => options[:max_stderr_bytes]}

    unless Enum.all?(limits, fn {_, limit} -> is_integer(limit) and limit in 0..16_777_216 end),
      do: raise(ArgumentError, "stream limits must be 0..16 MiB")

    total_limit =
      case options[:max_total_bytes] do
        nil -> Enum.sum(Map.values(limits))
        value -> value
      end

    unless is_integer(total_limit) and total_limit in 0..33_554_432 and
             is_integer(options[:max_chunks]) and options[:max_chunks] in 1..65_536 and
             Deadline.remaining(deadline) <= 600_000 do
      raise ArgumentError,
            "limits require 0..32 MiB combined, 1..65536 chunks and at most 600000 ms"
    end

    payload =
      NativeProtocol.process(executable, arguments,
        cwd: options[:cwd],
        env: Keyword.get_lazy(options, :env, &System.get_env/0)
      )

    %{
      payload: payload,
      limits: limits,
      total_limit: total_limit,
      max_chunks: options[:max_chunks],
      deadline: deadline
    }
  end

  defp run_worker(spec) do
    caller = self()
    reply = :erlang.alias()
    token = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        parent_monitor = Process.monitor(caller)
        result = execute(Map.merge(spec, %{parent_monitor: parent_monitor, token: token}))
        send(reply, {token, result})
      end)

    try do
      receive do
        {^token, result} ->
          result

        {:DOWN, ^monitor, :process, ^worker, reason} ->
          {:error,
           %Error{
             kind: :worker_failed,
             phase: :capture,
             details: %{reason: classify_exit(reason), cleanup: :unknown}
           }}
      after
        Deadline.remaining(spec.deadline) + @cleanup_ms ->
          send(worker, {:retire, token})
          {:error, %Error{kind: :timeout, phase: :retire, details: %{cleanup: :unknown}}}
      end
    after
      LibTmux.Transport.Reply.close(reply, token)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp execute(spec) do
    if Deadline.remaining(spec.deadline) == 0,
      do: {:error, %Error{kind: :timeout, phase: :admission, certainty: :no_write}},
      else: open(spec)
  end

  defp open(spec) do
    case start_port(spec) do
      {:error, error} ->
        {:error, error}

      {:ok, port} ->
        state =
          Map.merge(spec, %{
            port: port,
            chunks: %{1 => [], 2 => []},
            bytes: %{1 => 0, 2 => 0},
            count: 0,
            started: false
          })

        try do
          remaining = Deadline.remaining(spec.deadline)

          cond do
            remaining == 0 ->
              abort(state, :timeout, :admission, %{}, :no_write)

            send_port(
              port,
              NativeProtocol.open_frame(spec.payload, input: :closed, timeout: remaining)
            ) ->
              await(state)

            true ->
              abort(state, :resource_limit, :write, %{reason: :helper_busy}, :no_write)
          end
        after
          close_port(port)
        end
    end
  end

  defp start_port(_spec) do
    {:ok,
     Port.open({:spawn_executable, Native.executable()}, [
       :binary,
       :exit_status,
       {:packet, 2}
     ])}
  rescue
    error in ErlangError ->
      {:error,
       %Error{
         kind: :launch_failed,
         phase: :spawn,
         certainty: :no_write,
         details: %{reason: classify_exit(error.original)}
       }}
  end

  defp await(state) do
    port = state.port
    parent = state.parent_monitor
    token = state.token

    receive do
      {^port, {:data, data}} ->
        frame(state, data)

      {^port, {:exit_status, status}} ->
        failure(state, :transport_closed, :capture, %{helper_status: status, cleanup: :unknown})

      {:EXIT, ^port, :normal} ->
        await(state)

      {:EXIT, ^port, reason} ->
        failure(state, :transport_closed, :capture, %{
          reason: classify_exit(reason),
          cleanup: :unknown
        })

      {:DOWN, ^parent, :process, _caller, _reason} ->
        abort(state, :cancelled, :capture)

      {:retire, ^token} ->
        abort(state, :timeout, :capture)
    after
      Deadline.remaining(state.deadline) -> abort(state, :timeout, :capture)
    end
  end

  defp frame(%{started: false} = state, <<?S, _diagnostic_pid::32>>) do
    state = %{state | started: true}
    grant(state, 1)
    grant(state, 2)
    await(state)
  end

  defp frame(%{started: true} = state, <<?D, stream, data::binary>>)
       when stream in [1, 2] and byte_size(data) in 1..@chunk_bytes do
    if state.count >= state.max_chunks do
      abort(state, :resource_limit, :capture, %{reason: :chunks})
    else
      retain(state, stream, data)
    end
  end

  defp frame(state, <<?Z, stream>>) when stream in [1, 2], do: await(state)

  defp frame(state, <<?E, reason, status::32>>) when reason in 0..3 do
    send_port(state.port, "T")
    cleanup = retire(state.port, Deadline.new(@cleanup_ms), true)

    if cleanup == :retired and reason == 0 and Deadline.remaining(state.deadline) > 0 do
      {:ok, Map.merge(capture(state), %{exit_status: status, cleanup: :retired})}
    else
      failure(
        state,
        if(reason == 2 or Deadline.remaining(state.deadline) == 0,
          do: :timeout,
          else: :transport_closed
        ),
        :capture,
        %{exit_status: status, cleanup: cleanup}
      )
    end
  end

  defp frame(state, <<?F, kind, number::32>>) when kind in 1..4 do
    if kind != 4, do: send_port(state.port, "T")
    cleanup = retire(state.port, Deadline.new(@cleanup_ms), kind != 4)

    if kind == 2,
      do: failure(state, :launch_failed, :spawn, %{errno: number, cleanup: cleanup}, :no_write),
      else:
        failure(state, :transport_failed, :capture, %{
          reason: kind,
          errno: number,
          cleanup: cleanup
        })
  end

  defp frame(state, _data), do: abort(state, :protocol_error, :parse)

  defp retain(state, stream, data) do
    stream_available = max(state.limits[stream] - state.bytes[stream], 0)
    total_available = max(state.total_limit - state.bytes[1] - state.bytes[2], 0)
    available = min(stream_available, total_available)
    retained = binary_part(data, 0, min(byte_size(data), available)) |> :binary.copy()

    state = %{
      state
      | chunks: Map.update!(state.chunks, stream, &[retained | &1]),
        bytes: Map.update!(state.bytes, stream, &(&1 + byte_size(data))),
        count: state.count + 1
    }

    if byte_size(data) > available do
      abort(state, :resource_limit, :capture, %{
        reason:
          if(total_available < stream_available,
            do: :total_bytes,
            else: if(stream == 1, do: :stdout_bytes, else: :stderr_bytes)
          )
      })
    else
      grant(state, stream)
      await(state)
    end
  end

  defp grant(state, stream) do
    available =
      min(
        state.limits[stream] - state.bytes[stream],
        state.total_limit - state.bytes[1] - state.bytes[2]
      )

    size = min(@chunk_bytes, max(available + 1, 1))
    send_port(state.port, <<?R, stream, size::16>>)
  end

  defp abort(state, kind, phase, details \\ %{}, certainty \\ :unknown) do
    send_port(state.port, "Q")
    cleanup = retire(state.port, Deadline.new(@cleanup_ms), false)
    failure(state, kind, phase, Map.put(details, :cleanup, cleanup), certainty)
  end

  defp retire(port, deadline, evidence) do
    receive do
      {^port, {:data, <<?E, _reason, _status::32>>}} ->
        send_port(port, "T")
        retire(port, deadline, true)

      {^port, {:data, <<?F, kind, _number::32>>}} when kind in 1..4 ->
        if kind != 4, do: send_port(port, "T")
        retire(port, deadline, evidence or kind != 4)

      {^port, {:data, _data}} ->
        retire(port, deadline, evidence)

      {^port, {:exit_status, _status}} ->
        if(evidence, do: :retired, else: :unknown)

      {:EXIT, ^port, :normal} ->
        retire(port, deadline, evidence)

      {:EXIT, ^port, _reason} ->
        :unknown
    after
      Deadline.remaining(deadline) -> :unknown
    end
  end

  defp capture(state) do
    %{
      stdout: state.chunks[1] |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: state.chunks[2] |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp failure(state, kind, phase, details, certainty \\ :unknown) do
    {:error,
     %Error{
       kind: kind,
       phase: phase,
       certainty: certainty,
       details: Map.merge(capture(state), details)
     }}
  end

  defp send_port(port, data) do
    Port.command(port, data, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp classify_exit(reason) when is_atom(reason), do: reason
  defp classify_exit(_reason), do: :other
end
