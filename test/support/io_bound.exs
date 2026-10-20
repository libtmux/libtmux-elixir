helper = System.fetch_env!("LIBTMUX_IO_HELPER")
parent = self()
string = fn value -> <<byte_size(value)::16, value::binary>> end

{owner, monitor} =
  spawn_monitor(fn ->
    port = Port.open({:spawn_executable, helper}, [:binary, :exit_status, {:packet, 2}])
    code = "import os\nwhile True:\n os.write(1,b'x'*8192)\n os.write(2,b'y'*8192)"
    args = [System.find_executable("python3"), "-c", code]

    true =
      Port.command(port, [
        <<?O, 2, 0, 0::32>>,
        string.(File.cwd!()),
        <<length(args)::16>>,
        Enum.map(args, string),
        <<0::16>>
      ])

    receive do
      {^port, {:data, <<?S, _child::32>>}} -> :ok
    after
      750 -> raise "helper did not launch"
    end

    true = Port.command(port, <<?R, 1, 8192::16>>)
    true = Port.command(port, <<?R, 2, 8192::16>>)

    streams =
      for _ <- 1..2 do
        receive do
          {^port, {:data, <<?D, stream, bytes::binary>>}} ->
            true = byte_size(bytes) <= 8192
            stream
        after
          750 -> raise "flood did not produce both streams"
        end
      end

    [1, 2] = Enum.sort(streams)
    :erlang.garbage_collect()
    {:os_pid, pid} = Port.info(port, :os_pid)
    send(parent, {:ready, self(), port, pid})

    receive do
      :finish -> :ok
    end
  end)

try do
  receive do
    {:ready, ^owner, port, helper_pid} ->
      script =
        "import os,select,sys;f=os.pidfd_open(int(sys.argv[1]));p=select.poll();p.register(f,select.POLLIN);print('watching',flush=True);assert p.poll(750);print('exited',flush=True)"

      watcher =
        Port.open({:spawn_executable, System.find_executable("python3")}, [
          :binary,
          :exit_status,
          {:line, 128},
          {:args, ["-c", script, Integer.to_string(helper_pid)]}
        ])

      receive do
        {^watcher, {:data, {:eol, "watching"}}} -> :ok
      after
        750 -> raise "watcher did not acquire live process handle"
      end

      true = :erlang.suspend_process(owner)
      true = Port.command(port, <<?R, 1, 8192::16>>)
      true = Port.command(port, <<?R, 2, 8192::16>>)
      true = Port.command(port, "Q")

      receive do
        {^watcher, {:data, {:eol, "exited"}}} -> :ok
      after
        750 -> raise "helper did not retire"
      end

      receive do
        {^watcher, {:exit_status, 0}} -> :ok
      after
        750 -> raise "watcher did not exit"
      end

      {:message_queue_len, messages} = Process.info(owner, :message_queue_len)
      {:binary, binaries} = Process.info(owner, :binary)

      bytes =
        binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reduce(0, fn {_, n, _}, sum -> sum + n end)

      true = messages <= 4
      true = bytes <= 65_536
      IO.puts(JSON.encode!(%{messages: messages, binary_bytes: bytes, streams: 2}))
      true = :erlang.resume_process(owner)
      send(owner, :finish)
  after
    950 -> raise "owner did not report live flood"
  end

  receive do
    {:DOWN, ^monitor, :process, ^owner, :normal} -> :ok
  after
    750 -> raise "owner did not exit"
  end
after
  if Process.alive?(owner), do: Process.exit(owner, :kill)
end
