defmodule LibTmux.Control.Scope do
  @moduledoc false
  alias LibTmux.{Control, Deadline, Error}
  alias LibTmux.Control.{ScopeFailure, Start}
  alias LibTmux.Transport.Reply

  def run(options, callback) when is_function(callback, 1) do
    entered_at = System.monotonic_time(:millisecond)
    {cleanup_ms, options} = Keyword.pop(options, :cleanup_timeout, 950)
    startup_ms = Keyword.get(options, :timeout, 5000)

    unless is_integer(cleanup_ms) and cleanup_ms in 1..950 and
             is_integer(startup_ms) and startup_ms in 1..600_000,
           do: raise(ArgumentError, "scope requires startup 1..600000ms and cleanup 1..950ms")

    deadline = Deadline.new(startup_ms, now: entered_at)
    reply = :erlang.alias()
    token = make_ref()
    caller = self()

    {owner, monitor} =
      spawn_monitor(fn -> own(options, entered_at, cleanup_ms, caller, reply, token) end)

    try do
      receive do
        {^token, {:started, {:ok, control}}} ->
          if Deadline.remaining(deadline) == 0 do
            failure(:timeout, :connect)
          else
            primary = invoke(callback, control)
            deadline = Deadline.new(cleanup_ms)
            send(owner, {token, {:finish, deadline}})
            resolve(primary, await_cleanup(owner, monitor, token, deadline))
          end

        {^token, {:started, {:error, error}}} ->
          {:error, error}

        {^token, {:started, {:raise, kind, reason, stack}}} ->
          :erlang.raise(kind, reason, stack)

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          failure(:scope_owner_lost, :connect)
      after
        Deadline.remaining(deadline) + cleanup_ms -> failure(:timeout, :connect)
      end
    after
      send(owner, {token, :cancel})
      Reply.close(reply, token)
      # This alias carries at most two replies: startup and cleanup.
      receive do
        {^token, _late_reply} -> :ok
      after
        0 -> :ok
      end

      Process.demonitor(monitor, [:flush])
    end
  end

  defp own(options, entered_at, cleanup_ms, caller, reply, token) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    started =
      try do
        Start.start(options, entered_at)
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      end

    case started do
      {:ok, root, control} ->
        send(reply, {token, {:started, {:ok, control}}})

        deadline =
          receive do
            {^token, {:finish, %Deadline{} = deadline}} -> deadline
            {^token, :cancel} -> Deadline.new(cleanup_ms)
            {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Deadline.new(cleanup_ms)
            {:EXIT, ^root, _reason} -> Deadline.new(cleanup_ms)
          end

        result = cleanup(root, control, deadline)
        send(reply, {token, {:cleaned, result}})

      failure ->
        send(reply, {token, {:started, failure}})
    end
  end

  defp invoke(callback, control) do
    try do
      {:return, callback.(control)}
    catch
      kind, reason -> {:raise, kind, reason, __STACKTRACE__}
    end
  end

  defp await_cleanup(owner, monitor, token, deadline) do
    receive do
      {^token, {:cleaned, result}} -> result
      {:DOWN, ^monitor, :process, ^owner, _reason} -> failure(:scope_owner_lost, :close)
    after
      Deadline.remaining(deadline) -> failure(:timeout, :close)
    end
  end

  defp cleanup(root, control, deadline) do
    monitor = Process.monitor(root)
    connection = Control.scope_close(control, deadline)

    stopped = stop_root(root, deadline)

    exited =
      receive do
        {:DOWN, ^monitor, :process, ^root, _reason} -> true
      after
        Deadline.remaining(deadline) -> false
      end

    Process.demonitor(monitor, [:flush])

    if connection == :ok and stopped == :ok and exited do
      :ok
    else
      {:error,
       %Error{
         kind: :cleanup_unknown,
         phase: :close,
         certainty: :unknown,
         details: %{connection: connection, root_stop: stopped, root_exited: exited}
       }}
    end
  end

  defp stop_root(root, deadline) do
    remaining = Deadline.remaining(deadline)

    try do
      cond do
        not Process.alive?(root) -> :ok
        remaining == 0 -> failure(:timeout, :close)
        true -> Supervisor.stop(root, :normal, remaining)
      end
    catch
      :exit, _reason -> failure(:root_stop_failed, :close)
    after
      if Process.alive?(root), do: Process.exit(root, :kill)
    end
  end

  defp resolve({:return, value}, :ok), do: {:ok, value}
  defp resolve({:raise, kind, reason, stack}, :ok), do: :erlang.raise(kind, reason, stack)

  defp resolve(primary, {:error, error}),
    do: {:error, %ScopeFailure{primary: primary, cleanup: error}}

  defp failure(kind, phase),
    do:
      {:error,
       %Error{kind: kind, phase: phase, certainty: :unknown, details: %{cleanup: :unknown}}}
end
