defmodule LibTmux.Server.Daemon do
  @moduledoc false
  # Owns one foreground tmux server (`tmux -D`) under the native helper. The
  # helper retires the server when this process or the VM dies, so a crashed
  # owner cannot leave a daemon behind. The starting process owns the server:
  # when it exits, the daemon stops and removes its directory.

  use GenServer

  alias LibTmux.{Command, Deadline, Error, Server}
  alias LibTmux.Transport.Native.Driver
  alias LibTmux.Transport.Native.Protocol

  @socket_name "tmux.sock"
  # sun_path is 108 bytes on Linux, and the terminating NUL takes one.
  @path_limit 107
  @cleanup_ms 750
  @tail_bytes 2048
  @max_probe_ms 32

  @start_keys [:executable, :root, :config_file, :env, :timeout]

  defstruct [
    :spec,
    :owner_monitor,
    :port,
    :server,
    :from,
    :stop_from,
    :stop_timer,
    :start_timer,
    phase: :new,
    delay: 1,
    terminal: nil,
    helper_exited: false,
    output: ""
  ]

  @doc "Validates start options and returns the daemon specification."
  def prepare(options) do
    with :ok <- keyword(options),
         :ok <- known(options),
         {:ok, executable} <- executable(options),
         {:ok, root} <- root(options),
         {:ok, config} <- config_file(options),
         {:ok, env} <- env(options),
         {:ok, timeout} <- timeout(options) do
      {:ok,
       %{
         executable: executable,
         root: root,
         config_file: config,
         env: env,
         timeout: timeout
       }}
    end
  end

  @doc "Starts the daemon for `owner` and returns the owned Server."
  def start(options, owner) do
    with {:ok, spec} <- prepare(options),
         {:ok, daemon} <- GenServer.start(__MODULE__, {spec, owner}) do
      try do
        GenServer.call(daemon, :open, :infinity)
      catch
        :exit, _reason ->
          {:error,
           %Error{kind: :launch_failed, phase: :spawn, details: %{reason: :daemon_exited}}}
      end
    end
  end

  @doc "Stops the daemon behind `server`, removing its directory."
  def stop(%Server{daemon: nil}, _timeout),
    do: {:error, %Error{kind: :not_owned, phase: :validation, certainty: :no_write}}

  def stop(%Server{daemon: daemon}, timeout) do
    if Process.alive?(daemon) do
      try do
        GenServer.call(daemon, {:stop, timeout}, :infinity)
      catch
        :exit, {reason, _call} when reason in [:noproc, :normal] -> :ok
      end
    else
      :ok
    end
  end

  # Validation

  defp keyword(options) do
    if Keyword.keyword?(options),
      do: :ok,
      else: invalid([:options], "expected a keyword list")
  end

  defp known(options) do
    case Keyword.keys(options) -- @start_keys do
      [] -> :ok
      [key | _] -> invalid([:options, key], "unknown option for starting a server")
    end
  end

  defp executable(options) do
    case Keyword.fetch(options, :executable) do
      {:ok, value} ->
        if path?(value),
          do: {:ok, value},
          else: invalid([:options, :executable], "expected an absolute NUL-free path")

      :error ->
        invalid([:options, :executable], "required: the absolute path of the tmux executable")
    end
  end

  defp root(options) do
    root = Keyword.get_lazy(options, :root, &System.tmp_dir!/0)

    cond do
      not path?(root) ->
        invalid([:options, :root], "expected an absolute NUL-free directory")

      not File.dir?(root) ->
        invalid([:options, :root], "expected an existing directory")

      true ->
        # The directory name is fixed-length, so the socket path length is known now.
        probe = Path.join([root, "libtmux-" <> String.duplicate("0", 16), @socket_name])

        if byte_size(probe) > @path_limit,
          do:
            invalid(
              [:options, :root],
              "the socket path would exceed the #{@path_limit} bytes of sun_path"
            ),
          else: {:ok, root}
    end
  end

  defp config_file(options) do
    value = Keyword.get(options, :config_file, "/dev/null")

    if path?(value),
      do: {:ok, value},
      else: invalid([:options, :config_file], "expected an absolute NUL-free path")
  end

  defp env(options) do
    overlay = Keyword.get(options, :env, %{})

    if is_map(overlay) and
         Enum.all?(overlay, fn {key, value} -> is_binary(key) and is_binary(value) end),
       do: {:ok, overlay},
       else: invalid([:options, :env], "expected a map of binary names to binary values")
  end

  defp timeout(options) do
    value = Keyword.get(options, :timeout, 5000)

    if is_integer(value) and value in 1..600_000,
      do: {:ok, value},
      else: invalid([:options, :timeout], "expected an integer timeout in 1..600000ms")
  end

  defp path?(value),
    do:
      is_binary(value) and Path.type(value) == :absolute and
        :binary.match(value, <<0>>) == :nomatch

  defp invalid(path, reason),
    do:
      {:error,
       %Error{
         kind: :invalid_command,
         phase: :validation,
         certainty: :no_write,
         path: path,
         details: %{reason: reason}
       }}

  # GenServer

  @impl true
  def init({spec, owner}) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{spec: spec, owner_monitor: Process.monitor(owner)}}
  end

  @impl true
  def handle_call(:open, from, %{phase: :new} = state) do
    spec = state.spec

    directory =
      Path.join(
        spec.root,
        "libtmux-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    socket = Path.join(directory, @socket_name)
    spec = Map.merge(spec, %{directory: directory, socket: socket})
    state = %{state | spec: spec}

    with :ok <- make_directory(directory),
         {:ok, payload} <- payload(spec),
         {:ok, port} <- open_port(payload) do
      timer = Process.send_after(self(), :start_deadline, spec.timeout)
      {:noreply, %{state | port: port, from: from, phase: :opening, start_timer: timer}}
    else
      {:error, error} ->
        File.rm_rf(directory)
        {:stop, :normal, {:error, error}, state}
    end
  end

  def handle_call({:stop, timeout}, from, %{phase: phase} = state)
      when phase in [:running, :exited] do
    cond do
      state.stop_from != nil ->
        {:reply, {:error, %Error{kind: :stop_failed, phase: :retire, details: %{reason: :busy}}},
         state}

      state.terminal == nil ->
        deadline = Deadline.new(timeout)
        kill_server(state, timeout)
        timer = Process.send_after(self(), :stop_deadline, Deadline.remaining(deadline))
        finish_stop(%{state | stop_from: from, stop_timer: timer})

      true ->
        finish_stop(%{state | stop_from: from})
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode(data) do
      {:ok, frame} -> frame(frame, state)
      {:error, _error} -> fail(state, :protocol_error, :parse, %{})
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    terminal = state.terminal || {:helper, status}
    died(%{state | terminal: terminal, helper_exited: true})
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  def handle_info(:probe, %{phase: :probing} = state) do
    if answering?(state.spec.socket) do
      Process.cancel_timer(state.start_timer)
      server = %{server(state.spec) | daemon: self()}
      GenServer.reply(state.from, {:ok, server})
      {:noreply, %{state | phase: :running, server: server, from: nil, start_timer: nil}}
    else
      Process.send_after(self(), :probe, state.delay)
      {:noreply, %{state | delay: min(state.delay * 2, @max_probe_ms)}}
    end
  end

  def handle_info(:start_deadline, %{phase: phase} = state) when phase in [:opening, :probing],
    do: fail(state, :timeout, :start, %{})

  def handle_info(:stop_deadline, %{stop_from: from} = state) when from != nil do
    GenServer.reply(
      from,
      {:error, %Error{kind: :stop_failed, phase: :retire, details: %{reason: :still_answering}}}
    )

    {:noreply, %{state | stop_from: nil, stop_timer: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, state) do
    {retired, state} = retire(state)

    if retired == :retired and state.spec[:directory],
      do: File.rm_rf(state.spec.directory)

    :ok
  end

  # Frames from the helper

  defp frame({:started, _diagnostic_pid}, %{phase: :opening} = state) do
    grant(state.port, :stdout)
    grant(state.port, :stderr)
    send(self(), :probe)
    {:noreply, %{state | phase: :probing}}
  end

  defp frame({:data, stream, bytes}, state) do
    grant(state.port, stream)
    {:noreply, %{state | output: tail(state.output <> bytes)}}
  end

  defp frame({:terminal, reason, status}, state) do
    send_port(state.port, "T")
    died(%{state | terminal: {:terminal, reason, status}})
  end

  defp frame({:failed, kind, errno}, state) do
    send_port(state.port, "T")
    died(%{state | terminal: {:failed, kind, errno}})
  end

  defp frame(_ignored, state), do: {:noreply, state}

  defp died(%{phase: :running} = state), do: settle(%{state | phase: :exited})
  defp died(state), do: settle(state)

  # A start fails once the helper has retired the server; a stop completes then.
  defp settle(%{terminal: nil} = state), do: {:noreply, state}
  defp settle(%{helper_exited: false} = state), do: {:noreply, state}

  defp settle(%{phase: phase} = state) when phase in [:opening, :probing] do
    Process.cancel_timer(state.start_timer)
    File.rm_rf(state.spec.directory)

    {kind, error_phase, details} =
      case state.terminal do
        {:helper, status} -> {:launch_failed, :spawn, %{helper_status: status}}
        {:failed, 2, errno} -> {:launch_failed, :spawn, %{errno: errno}}
        {:failed, kind, errno} -> {:server_start_failed, :start, %{reason: kind, errno: errno}}
        {:terminal, _reason, status} -> {:server_start_failed, :start, %{exit_status: status}}
      end

    error = %Error{
      kind: kind,
      phase: error_phase,
      certainty: :unknown,
      details: Map.put(details, :output, state.output)
    }

    GenServer.reply(state.from, {:error, error})
    {:stop, :normal, %{state | port: nil}}
  end

  defp settle(%{stop_from: from} = state) when from != nil, do: finish_stop(state)
  defp settle(state), do: {:noreply, %{state | phase: :exited}}

  defp finish_stop(%{terminal: terminal, helper_exited: true} = state) when terminal != nil do
    if state.stop_timer, do: Process.cancel_timer(state.stop_timer)

    case File.rm_rf(state.spec.directory) do
      {:ok, _files} ->
        GenServer.reply(state.stop_from, :ok)
        {:stop, :normal, %{state | port: nil}}

      {:error, reason, path} ->
        error = %Error{
          kind: :cleanup_failed,
          phase: :retire,
          details: %{reason: reason, retired: true, path_kind: path_kind(path)}
        }

        GenServer.reply(state.stop_from, {:error, error})
        {:noreply, %{state | stop_from: nil, stop_timer: nil, phase: :exited}}
    end
  end

  defp finish_stop(state), do: {:noreply, state}

  defp path_kind(path), do: if(File.dir?(path), do: :directory, else: :file)

  defp fail(state, kind, phase, details) do
    {_retired, state} = retire(state)
    if state.start_timer, do: Process.cancel_timer(state.start_timer)
    File.rm_rf(state.spec.directory)

    error = %Error{
      kind: kind,
      phase: phase,
      certainty: :unknown,
      details: Map.put(details, :output, state.output)
    }

    GenServer.reply(state.from, {:error, error})
    {:stop, :normal, %{state | port: nil}}
  end

  # Commands and process management

  defp make_directory(directory) do
    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      :ok
    else
      {:error, reason} ->
        {:error,
         %Error{
           kind: :launch_failed,
           phase: :spawn,
           certainty: :no_write,
           details: %{reason: reason}
         }}
    end
  end

  defp payload(spec) do
    env = spec |> base_env() |> Map.put("TMUX_TMPDIR", spec.directory)

    Protocol.prepare_process(
      spec.executable,
      ["-D", "-S", spec.socket, "-f", spec.config_file],
      cwd: File.cwd!(),
      env: env,
      keep_tmux_context: false
    )
  end

  defp open_port(payload) do
    case Driver.open([]) do
      {:ok, port} ->
        if send_port(port, Protocol.open_frame(payload, input: :closed, timeout: 0)) do
          {:ok, port}
        else
          Port.close(port)

          {:error,
           %Error{
             kind: :launch_failed,
             phase: :spawn,
             certainty: :no_write,
             details: %{reason: :helper_busy}
           }}
        end

      {:error, reason} ->
        {:error,
         %Error{
           kind: :launch_failed,
           phase: :spawn,
           certainty: :no_write,
           details: %{reason: reason}
         }}
    end
  end

  defp server(spec) do
    Server.new(executable: spec.executable, socket: spec.socket, env: base_env(spec))
  end

  # The daemon and its panes never see the tmux session this program may run in.
  defp base_env(spec),
    do: Map.drop(Map.merge(System.get_env(), spec.env), ["TMUX", "TMUX_PANE"])

  defp kill_server(state, timeout) do
    # The command may fail because the server just exited; the helper's terminal
    # frame, not this result, says whether it did.
    Server.run(state.server, Command.new("kill-server", []), timeout: timeout)
  end

  defp grant(port, stream), do: send_port(port, Protocol.read_frame(stream, 8192))

  defp send_port(port, data) do
    Port.command(port, data, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  defp answering?(socket) do
    case :gen_tcp.connect({:local, String.to_charlist(socket)}, 0, [:local, active: false], 100) do
      {:ok, connection} ->
        :gen_tcp.close(connection)
        true

      {:error, _reason} ->
        false
    end
  end

  defp tail(output) when byte_size(output) <= @tail_bytes, do: output
  defp tail(output), do: binary_part(output, byte_size(output) - @tail_bytes, @tail_bytes)

  # Stops the server through the helper and waits for its terminal proof.
  defp retire(%{port: port} = state) when port != nil do
    unless state.terminal, do: send_port(port, "Q")
    deadline = Deadline.new(@cleanup_ms)
    retire(state, deadline)
  end

  defp retire(state), do: {:retired, state}

  defp retire(%{terminal: terminal, helper_exited: true} = state, _deadline)
       when terminal != nil,
       do: {:retired, state}

  defp retire(%{port: port} = state, deadline) do
    receive do
      {^port, {:data, data}} ->
        case Protocol.decode(data) do
          {:ok, {:terminal, reason, status}} ->
            send_port(port, "T")
            retire(%{state | terminal: {:terminal, reason, status}}, deadline)

          {:ok, {:failed, kind, errno}} when kind in 1..3 ->
            send_port(port, "T")
            retire(%{state | terminal: {:failed, kind, errno}}, deadline)

          _other ->
            retire(state, deadline)
        end

      {^port, {:exit_status, _status}} ->
        retire(%{state | helper_exited: true}, deadline)

      {:EXIT, ^port, _reason} ->
        retire(%{state | helper_exited: true}, deadline)
    after
      Deadline.remaining(deadline) -> {:unknown, state}
    end
  end
end
