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

  @doc "Names a native helper and the client it owns, and fingerprints their executables."
  def watch_native(helper, client) do
    helper = identity!(helper)
    client = identity!(client)

    ready = %{
      "kind" => "ready",
      "helper_pid" => elem(helper, 0),
      "helper_sha256" => sha256(elem(helper, 0)),
      "client_pid" => elem(client, 0),
      "client_sha256" => sha256(elem(client, 0))
    }

    %{helper: helper, client: client, ready: ready}
  end

  @doc "Terminates the watched client and times how long it and its helper take to exit."
  def terminate_native(%{helper: helper, client: client}) do
    started = System.monotonic_time(:microsecond)
    {client_pid, _instance} = client
    true = alive?(client)
    {_output, 0} = System.cmd("kill", ["-TERM", Integer.to_string(client_pid)])

    case await_exit([helper, client], 750) do
      :ok ->
        elapsed = (System.monotonic_time(:microsecond) - started) / 1000
        %{"kind" => "exited", "milliseconds" => elapsed}

      {:alive, pids} ->
        raise "owned client/helper did not exit within 750ms: #{inspect(pids)}"
    end
  end

  defp sha256(pid),
    do: :sha256 |> :crypto.hash(File.read!("/proc/#{pid}/exe")) |> Base.encode16(case: :lower)

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
