defmodule LibTmux.ControlShortWriteIntegrationTest do
  use ExUnit.Case, async: false

  alias LibTmux.{Control, Deadline, Operation, Server}
  alias LibTmux.Control.{Births, Records, Request}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag reason:
               "Builds a private native helper to observe an actual unacknowledged kernel short write"

  defmodule Driver do
    @behaviour LibTmux.Transport.Native.Driver

    @impl true
    def open(options) do
      first = :atomics.add_get(options[:opens], 1, 1) == 1
      path = if first, do: to_charlist(options[:socket]), else: false
      nonce = if first, do: to_charlist(options[:nonce]), else: false

      {:ok,
       Port.open({:spawn_executable, Keyword.fetch!(options, :executable)}, [
         :binary,
         :exit_status,
         {:packet, 2},
         {:env, [{~c"LIBTMUX_SHORT_WRITE_SOCKET", path}, {~c"LIBTMUX_SHORT_WRITE_NONCE", nonce}]}
       ])}
    end

    @impl true
    defdelegate command(port, frame), to: LibTmux.Transport.Native.Driver

    @impl true
    defdelegate close(port), to: LibTmux.Transport.Native.Driver
  end

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ltx-short-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    source = File.read!(Path.join(__DIR__, "../c_src/owned_io.c"))
    header = Path.join(__DIR__, "support/short_write.h") |> Path.expand()
    needle = "static void write_child(struct state *s) {\n"

    source =
      source
      |> replace_once!(needle, "#include \"#{header}\"\n\n" <> needle)
      |> replace_once!(
        "    if (size > 0) s->write_sent += (size_t)size;",
        "    short_write_after(s, size);\n" <>
          "    if (size > 0) s->write_sent += (size_t)size;"
      )
      |> replace_once!(
        "if (s.write_pending && !s.write_failed && s.write_sent < s.write_size) fds[6].fd = s.child_in;",
        "if (s.write_pending && !s.write_failed && s.write_sent < s.write_size && short_write_gate(&s)) fds[6].fd = s.child_in;"
      )

    input = Path.join(directory, "owned_io.c")
    executable = Path.join(directory, "owned_io")
    File.write!(input, source)
    compiler = System.find_executable("cc") || raise "native integration requires a C11 compiler"

    assert {"", 0} =
             System.cmd(
               compiler,
               [
                 "-std=c11",
                 "-O2",
                 "-Wall",
                 "-Wextra",
                 "-Werror",
                 input,
                 "-o",
                 executable
               ],
               stderr_to_stdout: true
             )

    IO.puts(
      JSON.encode!(%{
        short_write_build: %{
          source_sha256: sha256(input),
          header_sha256: sha256(header),
          executable_sha256: sha256(executable)
        }
      })
    )

    %{directory: directory, executable: executable}
  end

  test "cancellation retires an unacknowledged short write before another line", context do
    socket_path = Path.join(context.directory, "progress")
    assert {:ok, socket} = :socket.open(:local, :dgram, :default)
    on_exit(fn -> :socket.close(socket) end)
    assert :ok = :socket.bind(socket, %{family: :local, path: socket_path})
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: tmux_socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: tmux_socket, cwd: "/", env: %{})

    parent =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor,
        restart: :temporary
      })

    spec =
      Control.child_spec(
        server: server,
        session: {:existing, "$0"},
        lane: :host_qualified,
        timeout: 800,
        capacity: 2,
        metadata_capacity: 4,
        waiter_capacity: 1
      )

    # Select a private helper after public preparation; this is no public option.
    %{start: {module, function, [prepared]}} = spec
    nonce = Base.encode16(:crypto.strong_rand_bytes(16))
    opens = :atomics.new(1, signed: false)

    driver =
      {Driver, [executable: context.executable, socket: socket_path, nonce: nonce, opens: opens]}

    prepared = %{prepared | options: Keyword.put(prepared.options, :driver, driver)}

    assert {:ok, root, control} =
             Supervisor.start_child(parent, %{spec | start: {module, function, [prepared]}})

    endpoint = control.endpoint
    [{:host, host}] = :ets.lookup(control.view, :host)
    persistent = monitor_actors([parent, root, host, endpoint.manager])
    original = track_epoch(endpoint)
    deadline = Deadline.new(800)

    request = Request.set_user_option("@short_prefix", String.duplicate("x", 12_000))

    assert {:ok, operation} =
             Control.submit(control, request, timeout: Deadline.remaining(deadline))

    assert {:ok,
            {_sender,
             <<?P, helper::32, child::32, id::32, written::32, fragment::32, capacity::32,
               queued::32, before_write::32, observed_nonce::binary-size(32)>>}} =
             :socket.recvfrom(socket, 128, [], Deadline.remaining(deadline))

    assert helper == original.helper and child == original.child and observed_nonce == nonce
    assert id == 1 and written == 4096 and fragment == 8192
    assert capacity == 4096 and queued in 0..written and before_write == 0

    IO.puts(
      JSON.encode!(%{
        native_short_write: %{
          id: id,
          written: written,
          fragment: fragment,
          actual_pipe_capacity: capacity,
          queued: queued,
          before_write: before_write
        }
      })
    )

    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    guardian = :sys.get_state(roles.guardian, Deadline.remaining(deadline))
    assert %{id: ^id, bytes: ^fragment, lease: lease} = guardian.pending
    assert lease === operation.lease

    assert {:ok, %{life: %{wire: :writing, written: 0, result: nil}, reply: nil}} =
             Records.fetch(endpoint.records, operation.lease)

    assert {:ok, sibling} =
             Control.submit(control, Request.set_user_option("@short_sibling", "second"),
               timeout: Deadline.remaining(deadline)
             )

    observer = self()

    {awaiter, monitor} =
      spawn_monitor(fn ->
        receive do
          :await -> send(observer, {:await_returned, Operation.await(operation, timeout: 800)})
        end
      end)

    on_exit(fn -> Process.exit(awaiter, :kill) end)
    waiter = watch_waiter(endpoint.manager, awaiter)
    send(awaiter, :await)
    assert_receive {^waiter, :registered}, Deadline.remaining(deadline)
    Process.exit(awaiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^awaiter, :killed}, Deadline.remaining(deadline)
    assert_receive {^waiter, :released}, Deadline.remaining(deadline)
    assert Operation.result(operation) == :pending
    assert Operation.result(sibling) == :pending
    assert {:ok, %{phase: :ready}} = Control.status(control)

    retirement = watch_retirement(endpoint.manager, endpoint.generation)
    assert :ok = Operation.stop(operation)
    assert {:ok, %{phase: phase, generation: generation}} = Control.status(control)
    assert phase in [:closing, :retired]
    assert generation == endpoint.generation
    assert Deadline.remaining(deadline) > 0
    retire_epoch(original, deadline)
    assert_receive {^retirement, :retired}, Deadline.remaining(deadline)
    assert {:ok, %{phase: :retired, generation: ^generation}} = Control.status(control)

    assert {:ok, %{wire: :retired, result: %{outcome: :unknown, certainty: :unknown} = result}} =
             Operation.status(operation)

    assert {:ok, %{outcome: :skipped, certainty: :no_write} = skipped} = Operation.result(sibling)
    refute_receive {:await_returned, _result}, 0

    for name <- ["@short_prefix", "@short_sibling"] do
      assert {"", 0} = OwnedTmux.command(fixture, ["show-options", "-sqv", name])
    end

    assert Deadline.remaining(deadline) > 0

    assert {:ok, replacement} = Control.reconnect(control, timeout: 800)
    assert replacement.endpoint.generation == endpoint.generation + 1
    assert replacement.endpoint.instance == endpoint.instance
    replacement_epoch = track_epoch(replacement.endpoint)
    assert :atomics.get(opens, 1) == 2
    assert {:ok, ^result} = Operation.result(operation)
    assert {:ok, ^skipped} = Operation.result(sibling)
    deadline = Deadline.new(800)

    for old <- [operation, sibling],
        do: assert(:ok = Operation.forget(old, timeout: Deadline.remaining(deadline)))

    assert {:ok, fresh} =
             Control.submit(replacement, Request.set_user_option("@short_sibling", "replacement"),
               timeout: Deadline.remaining(deadline)
             )

    assert {:ok, %{outcome: :completed, certainty: :acknowledged}} =
             Operation.await(fresh, timeout: Deadline.remaining(deadline))

    assert {"", 0} = OwnedTmux.command(fixture, ["show-options", "-sqv", "@short_prefix"])

    assert {"replacement\n", 0} =
             OwnedTmux.command(fixture, ["show-options", "-sv", "@short_sibling"])

    assert Deadline.remaining(deadline) > 0

    cleanup = Deadline.new(950)
    assert :ok = Control.close(replacement, timeout: min(800, Deadline.remaining(cleanup)))
    retire_epoch(replacement_epoch, cleanup)
    assert :ok = :sys.terminate(parent, :normal, Deadline.remaining(cleanup))
    exited(persistent, cleanup)
    assert Deadline.remaining(cleanup) > 0
    assert :ok = :socket.close(socket)
    assert OwnedTmux.alive?(fixture)
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
  end

  defp track_epoch(endpoint) do
    assert {:ok, %{roles: roles}} = Births.snapshot(endpoint.births)
    guardian = :sys.get_state(roles.guardian, 500)
    {:os_pid, helper} = Port.info(guardian.handle, :os_pid)

    %{
      actors: monitor_actors(Map.values(roles)),
      native: OwnedTmux.watch_processes([helper, guardian.child]),
      helper: helper,
      child: guardian.child
    }
  end

  defp retire_epoch(epoch, deadline) do
    exited(epoch.actors, deadline)
    assert :ok = OwnedTmux.await_exit(epoch.native)
  end

  defp monitor_actors(pids), do: for(pid <- pids, do: {pid, Process.monitor(pid)})

  defp exited(monitors, deadline) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, Deadline.remaining(deadline)
      refute Process.alive?(pid)
    end
  end

  defp watch_waiter(manager, receiver) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           nil, {:noreply, state}, _name ->
             case Enum.find(Map.values(state.waiters.active), &(&1.ticket.caller == receiver)) do
               %{ticket: ticket} ->
                 send(observer, {token, :registered})
                 {ticket.slot, ticket.generation}

               nil ->
                 nil
             end

           {slot, generation} = previous, {:noreply, state}, _name ->
             case :ets.lookup(state.waiters.inbox.table, slot) do
               [{^slot, %{state: :free, generation: ^generation}}]
               when state.waiters.active == %{} ->
                 send(observer, {token, :released})
                 :done

               _ ->
                 previous
             end

           previous, _event, _name ->
             previous
         end, nil},
        500
      )

    token
  end

  defp watch_retirement(manager, generation) do
    observer = self()
    token = make_ref()

    :ok =
      :sys.install(
        manager,
        {token,
         fn
           _previous, {:noreply, %{phase: :closed, generation: ^generation}}, _name ->
             send(observer, {token, :retired})
             :done

           previous, _event, _name ->
             previous
         end, nil},
        500
      )

    token
  end

  defp replace_once!(source, old, replacement) do
    assert length(:binary.matches(source, old)) == 1
    String.replace(source, old, replacement)
  end

  defp sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
