defmodule LibTmux.Test.Child do
  @moduledoc false
  # A BEAM child that does what a test tells it to, so no test embeds a shell
  # program. `argv/1` turns a list of steps into the command line of a bare VM
  # that runs them in order and exits 0 when they end.
  #
  #   {:stdout, bytes}, {:stderr, bytes}   write bytes
  #   {:env, names}          write the named variables as NAME=value, NUL-separated
  #   :pid                   write the VM's OS pid and a newline
  #   :ignore_term           ignore SIGTERM
  #   :read                  wait for one chunk on stdin
  #   {:flood, stream, line} write the line forever from a separate process
  #   {:detach, steps}       start another such VM in its own session, sharing stdout
  #   :hold                  wait forever
  #   {:exit, status}        halt with the status
  #
  # {:raw_pane, fifo} runs as a tmux pane program: it puts the pane's terminal in raw
  # mode, reports `R` to the fifo, prints a control-mode reply and a cursor position
  # request to the terminal, then copies every byte it reads from the terminal to the fifo.
  #
  # Three steps drive the native helper from other VMs, because only the VM that
  # starts a port holds the other end of its pipes. The helper takes its stdin from
  # the VM's, so the test's own port feeds it frames.
  #
  #   {:read_helper, helper}      read the helper's stdout here and print `helper PID`,
  #                              `started` at its first frame and `status N` once it
  #                              exits. Suspend the VM to stall the reader.
  #   {:read_first_frame, argv}   run a VM with argv, wait for the helper's first frame
  #                              from it, print `reader` and the Base16 of a term holding
  #                              the identities of that VM and the helper's child, then
  #                              close the pipe: a reader that leaves while stdin stays open
  #   {:helper_status, helper, path}  run the helper on this VM's stdin and stdout, and
  #                              write its exit status to the file

  # A VM takes longer to start than the shortest deadlines tests set, so a
  # deadline that a child must meet comes from `deadline/1`, not a constant.

  alias LibTmux.Test.Processes

  @start_key {__MODULE__, :start_ms}
  @flood_bytes 8192

  @doc """
  The command line of a VM that runs `steps`. It starts `erlexec` directly:
  the `erl` script needs `dirname` on PATH and, without it, loops forever in any
  directory but `/`, and a child may run with an empty environment.
  """
  def argv(steps) do
    root = to_string(:code.root_dir())
    bindir = Path.join([root, "erts-" <> to_string(:erlang.system_info(:version)), "bin"])
    env = System.find_executable("env") || raise "env is not on PATH"

    [env, "ROOTDIR=" <> root, "BINDIR=" <> bindir, "EMU=beam", "PROGNAME=erl"] ++
      [Path.join(bindir, "erlexec"), "-noshell", "-noinput", "-boot", "no_dot_erlang"] ++
      code_paths() ++
      ["-run", Atom.to_string(__MODULE__), "main", "-extra", encode(steps)]
  end

  @doc "The `-pa` flags that make this module and the Elixir standard library loadable."
  def code_paths do
    [
      "-pa",
      Path.dirname(to_string(:code.which(__MODULE__))),
      "-pa",
      Path.join(Application.app_dir(:elixir), "ebin")
    ]
  end

  @doc """
  A deadline of `milliseconds` for a child that must start first: the slowest
  of three measured VM starts, twice, plus the interval itself. A measured
  start is one sample and a loaded host can double it.
  """
  def deadline(milliseconds), do: milliseconds + 2 * start_ms()

  @doc "The slowest of three runs of a VM that starts and exits, in milliseconds."
  def start_ms do
    case :persistent_term.get(@start_key, nil) do
      nil ->
        [executable | arguments] = argv([])

        slowest =
          1..3
          |> Enum.map(fn _ ->
            started = System.monotonic_time(:millisecond)
            {_, 0} = System.cmd(executable, arguments, stderr_to_stdout: true)
            System.monotonic_time(:millisecond) - started
          end)
          |> Enum.max()

        :persistent_term.put(@start_key, slowest)
        slowest

      measured ->
        measured
    end
  end

  defp encode(steps) do
    steps |> Enum.map(&prepare/1) |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  end

  # The VM may run with an empty environment, so every executable is found here.
  defp prepare({:detach, steps}) do
    setsid = System.find_executable("setsid") || raise("setsid is not on PATH")
    {:spawn, [setsid, "-f" | argv(steps)]}
  end

  defp prepare(step), do: step

  ## The VM side.

  @doc false
  def main do
    [encoded] = :init.get_plain_arguments()

    steps =
      encoded
      |> List.to_string()
      |> Base.url_decode64!(padding: false)
      |> :erlang.binary_to_term([:safe])

    # Run apart from the boot sequence, which a step that never returns would
    # keep from finishing.
    spawn(fn -> run(steps) end)
    :ok
  end

  defp run(steps) do
    Enum.each(steps, &step/1)
    System.halt(0)
  catch
    kind, reason ->
      write(:stderr, Exception.format(kind, reason, __STACKTRACE__))
      System.halt(70)
  end

  defp step({:stdout, bytes}), do: write(:stdout, bytes)
  defp step({:stderr, bytes}), do: write(:stderr, bytes)
  defp step(:pid), do: write(:stdout, System.pid() <> "\n")
  defp step(:ignore_term), do: :ok = :os.set_signal(:sigterm, :ignore)
  defp step(:hold), do: Process.sleep(:infinity)
  defp step({:exit, status}), do: System.halt(status)

  defp step(:read) do
    stdin = open_stdin()

    receive do
      {^stdin, {:data, _bytes}} -> :ok
    end
  end

  defp step({:env, names}) do
    entries = "/proc/self/environ" |> File.read!() |> :binary.split(<<0>>, [:global, :trim_all])

    found =
      for name <- names, entry <- entries, String.starts_with?(entry, name <> "="), do: entry

    write(:stdout, Enum.join(found, <<0>>))
  end

  defp step({:flood, stream, line}) do
    chunk = String.duplicate(line <> "\n", div(@flood_bytes, byte_size(line) + 1))

    spawn(fn ->
      {:ok, device} = :file.open(device(stream), [:append, :raw, :binary])
      flood(device, chunk)
    end)
  end

  # A port that only writes leaves the child's stdout as this VM's own.
  defp step({:spawn, [executable | arguments]}),
    do: Port.open({:spawn_executable, executable}, [:out, args: arguments])

  defp step({:helper_status, helper, status_path}) do
    # Standard I/O stays with the helper's real peers, and the status comes
    # back over the port's own descriptors.
    port = Port.open({:spawn_executable, helper}, [:nouse_stdio, :exit_status])

    receive do
      {^port, {:exit_status, status}} -> File.write!(status_path, "#{status}\n")
    end
  end

  defp step({:read_first_frame, [executable | arguments]}) do
    port = Port.open({:spawn_executable, executable}, [:in, :binary, args: arguments])
    {:os_pid, vm} = Port.info(port, :os_pid)

    receive do
      {^port, {:data, <<_::16, ?S, child::32, _::binary>>}} ->
        # Name both processes now: the helper retires the child as soon as the pipe closes.
        names = [Processes.identity!(vm), Processes.identity!(child)]
        write(:stdout, "reader #{names |> :erlang.term_to_binary() |> Base.encode16()}\n")
    end

    Port.close(port)
  end

  defp step({:raw_pane, fifo}) do
    # stty reads the pane's terminal from the VM's own stdin.
    stty = System.find_executable("stty") || raise "stty is not on PATH"
    port = Port.open({:spawn_executable, stty}, [:in, :exit_status, args: ["raw", "-echo"]])

    receive do
      {^port, {:exit_status, 0}} -> :ok
    end

    {:ok, fifo} = :file.open(fifo, [:write, :raw, :binary])
    :ok = :file.write(fifo, "R")
    write(:stdout, "%begin 9 8 1\r\n%end 9 8 1\r\n\e[6n")
    copy(open_stdin(), fifo)
  end

  defp step({:read_helper, helper}) do
    port = Port.open({:spawn_executable, helper}, [:in, :exit_status, :binary])
    {:os_pid, pid} = Port.info(port, :os_pid)
    write(:stdout, "helper #{pid}\n")
    await_status(port, :starting)
  end

  defp await_status(port, phase) do
    receive do
      {^port, {:exit_status, status}} ->
        write(:stdout, "status #{status}\n")

      {^port, {:data, _bytes}} when phase == :starting ->
        write(:stdout, "started\n")
        await_status(port, :started)

      {^port, {:data, _bytes}} ->
        await_status(port, :started)
    end
  end

  # A raw read of /dev/stdin never sees a terminal's input, so read the descriptor.
  defp open_stdin, do: Port.open({:fd, 0, 1}, [:in, :binary])

  defp copy(stdin, fifo) do
    receive do
      {^stdin, {:data, bytes}} ->
        :ok = :file.write(fifo, bytes)
        copy(stdin, fifo)
    end
  end

  defp flood(device, chunk) do
    case :file.write(device, chunk) do
      :ok -> flood(device, chunk)
      {:error, _reason} -> System.halt(1)
    end
  end

  # Raw device files write straight to the descriptor, so a byte is out before
  # the next step or a halt.
  defp write(stream, bytes) do
    {:ok, device} = :file.open(device(stream), [:append, :raw, :binary])
    result = :file.write(device, bytes)
    :ok = :file.close(device)
    :ok = result
  end

  defp device(:stdout), do: "/dev/stdout"
  defp device(:stderr), do: "/dev/stderr"
end
