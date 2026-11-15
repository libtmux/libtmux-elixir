defmodule LibTmux.Test.Processes do
  @moduledoc false
  # The BEAM cannot hold a pidfd, so a test names a process by its start time
  # and polls /proc until that exact process is gone. A reused PID has another
  # start time and counts as gone.

  alias LibTmux.ProcessIdentity

  @doc "Names a live process, or raises when `pid` is not one."
  def identity!(pid) do
    {:ok, instance} = ProcessIdentity.read(pid)
    {pid, instance}
  end

  @doc "Whether the process the identity names is still running."
  def alive?({pid, instance}), do: ProcessIdentity.read(pid) == {:ok, instance}

  @doc "Waits until every named process has exited, or returns the ones still alive."
  def await_exit(identities, milliseconds \\ 750) do
    deadline = System.monotonic_time(:millisecond) + milliseconds
    await(identities, deadline, 1)
  end

  defp await(identities, deadline, delay) do
    case Enum.filter(identities, &alive?/1) do
      [] ->
        :ok

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:alive, Enum.map(alive, &elem(&1, 0))}
        else
          receive do
          after
            delay -> await(alive, deadline, min(delay * 2, 16))
          end
        end
    end
  end
end
