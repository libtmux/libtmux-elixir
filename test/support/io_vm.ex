defmodule LibTmux.Test.IoVm do
  @moduledoc false
  # Runs in a VM of its own, so a test can kill that VM, or only the process
  # that owns a native helper, and then check what happens to the helper's
  # process tree. It opens the helper with a child and prints the OS pids of the
  # helper, the child and a grandchild on one line. The child must print the
  # grandchild's pid as its first output.
  #
  # Arguments: `owner|vm`, a wait in milliseconds, the helper, then the child's argv.
  # In `owner` mode a port owner dies on a `kill` line from stdin and the VM stays up.

  alias LibTmux.Test.HelperPeer

  def run do
    [mode, wait, helper | argv] = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    wait = String.to_integer(wait)

    case mode do
      "owner" -> owner(helper, argv, wait)
      "vm" -> helper |> open(argv, wait) |> print()
    end

    Process.sleep(:infinity)
  end

  defp owner(helper, argv, wait) do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        send(parent, {:ready, open(helper, argv, wait)})
        Process.sleep(:infinity)
      end)

    receive do
      {:ready, pids} -> print(pids)
    after
      wait -> raise "the owner did not start the helper"
    end

    # A bare VM reads standard input as characters, not a binary.
    "kill\n" = "" |> IO.gets() |> to_string()
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^owner, :killed} -> :ok
    after
      wait -> raise "the owner did not die"
    end

    IO.puts("owner-down")
  end

  defp open(helper, argv, wait) do
    port = Port.open({:spawn_executable, helper}, [:binary, :exit_status, {:packet, 2}])
    true = Port.command(port, HelperPeer.open_frame(argv, timeout: 0))

    child =
      receive do
        {^port, {:data, <<?S, pid::32>>}} -> pid
      after
        wait -> raise "the helper did not start the child"
      end

    true = Port.command(port, <<?R, 1, 8192::16>>)

    grandchild =
      receive do
        {^port, {:data, <<?D, 1, line::binary>>}} -> line |> String.trim() |> String.to_integer()
      after
        wait -> raise "the child did not start a grandchild"
      end

    {:os_pid, helper_pid} = Port.info(port, :os_pid)
    {helper_pid, child, grandchild}
  end

  defp print({helper, child, grandchild}), do: IO.puts("#{helper} #{child} #{grandchild}")
end
