defmodule LibTmux.Control.Guardian do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 950

  alias LibTmux.{Command, Deadline, Error}
  alias LibTmux.Control.{Admission, Lifetime}
  alias LibTmux.Transport.Native.{Driver, Protocol}

  @sweep_ms 25
  @cleanup_ms 750

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    {driver, driver_options} = Keyword.get(options, :driver, {Driver, []})
    manager = Keyword.fetch!(options, :manager)
    router = Keyword.fetch!(options, :router)
    lifetime = Keyword.fetch!(options, :lifetime)
    generation = Keyword.fetch!(options, :generation)

    unless Lifetime.status(lifetime) == %{generation: generation, phase: :starting},
      do: raise(ArgumentError, "guardian requires the reserved starting lifetime")

    state = %{
      manager: manager,
      router: router,
      epoch: Keyword.fetch!(options, :epoch),
      lifetime: lifetime,
      generation: generation,
      pool: Keyword.fetch!(options, :pool),
      bootstrap: Keyword.fetch!(options, :bootstrap),
      bootstrap_state: :unused,
      deadline: Keyword.fetch!(options, :deadline),
      monitors: Map.new(Enum.uniq([manager, router]), &{Process.monitor(&1), &1}),
      manager_lost: false,
      phase: :starting,
      driver: driver,
      handle: nil,
      child: nil,
      pending: nil,
      next_write: 1,
      entries: %{},
      partial: nil,
      credit: make_ref(),
      stdout_credit: false,
      stdout_demand: false,
      stderr_bytes: 0,
      stderr_chunks: 0,
      stderr: [],
      terminal: nil,
      close_reason: nil
    }

    case driver.open(driver_options) do
      {:ok, handle} ->
        state = %{state | handle: handle}
        frame = Protocol.open_frame(Keyword.fetch!(options, :payload), input: :open, timeout: 0)
        Process.send_after(self(), :sweep, @sweep_ms)

        if driver.command(handle, frame),
          do: {:ok, state},
          else: {:ok, close(state, :port_busy)}

      {:error, _reason} ->
        Lifetime.abandon(lifetime, generation)
        {:stop, %Error{kind: :transport_unavailable, phase: :connect, certainty: :no_write}}
    end
  end

  @impl true
  def handle_info({:read, router, epoch, credit}, %{router: router, epoch: epoch} = state)
      when state.phase in [:starting, :ready] do
    if credit == state.credit and not state.stdout_credit and not state.stdout_demand do
      {:noreply, grant_stdout(%{state | stdout_demand: true})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:challenge, router, epoch, token, nonce},
        %{
          router: router,
          epoch: epoch,
          bootstrap: token,
          phase: :starting,
          bootstrap_state: :unused,
          pending: nil
        } = state
      ) do
    if Deadline.remaining(state.deadline) > 0 and is_binary(nonce) and
         byte_size(nonce) in 1..64 and Regex.match?(~r/\A[A-F0-9]+\z/, nonce) and
         Lifetime.status(state.lifetime) == %{generation: state.generation, phase: :starting} do
      command = Command.new("display-message", ["-p", nonce <> ~S":#{pid}"])
      line = Command.render(command) <> "\n"

      state = %{
        state
        | bootstrap_state: :writing,
          pending: %{id: 0, kind: :bootstrap, bytes: byte_size(line)}
      }

      {:noreply, write_native(state, 0, line)}
    else
      {:noreply, close(state, :invalid_bootstrap)}
    end
  end

  def handle_info(
        {:activate, router, epoch, token},
        %{
          router: router,
          epoch: epoch,
          bootstrap: token,
          phase: :starting,
          bootstrap_state: :written,
          pending: nil
        } = state
      ) do
    if Deadline.remaining(state.deadline) > 0 do
      case Lifetime.ready(state.lifetime, state.generation) do
        :ok ->
          notify(state, :active)
          {:noreply, %{state | phase: :ready}}

        {:error, _error} ->
          {:noreply, close(state, :stale_epoch)}
      end
    else
      {:noreply, close(state, :timeout)}
    end
  end

  def handle_info(
        {:write, router, epoch, token, lease, offset, total, bytes},
        %{router: router, epoch: epoch, phase: :ready} = state
      ) do
    case validate_write(state, token, lease, offset, total, bytes) do
      {:ok, entry} ->
        id = state.next_write

        state = %{
          state
          | entries: Map.put(state.entries, lease.slot, entry),
            partial: {lease.slot, lease.generation, token},
            next_write: id + 1,
            pending: %{
              id: id,
              kind: :operation,
              bytes: byte_size(bytes),
              token: token,
              lease: lease,
              entry: entry
            }
        }

        {:noreply, write_native(state, id, bytes)}

      {:error, %Error{kind: kind}} ->
        {:noreply, close(state, kind)}
    end
  end

  def handle_info(
        {:wire_retired, router, epoch, token, lease},
        %{router: router, epoch: epoch, phase: :ready} = state
      ) do
    with :ok <- Admission.verify_consumed(state.pool, lease),
         %{token: ^token, generation: generation, status: :awaiting} = entry <-
           Map.get(state.entries, lease.slot),
         true <- generation == lease.generation,
         true <- lease.expires_at > System.monotonic_time(:millisecond) do
      send_router(state, {:wire_retired, token, lease})

      {:noreply,
       %{state | entries: Map.put(state.entries, lease.slot, %{entry | status: :retired})}}
    else
      _ -> {:noreply, close(state, :invalid_retirement)}
    end
  end

  def handle_info({:close, owner, epoch, reason}, %{epoch: epoch} = state)
      when owner == state.manager or owner == state.router,
      do: {:noreply, close(state, reason)}

  def handle_info({handle, {:data, frame}}, %{handle: handle} = state) do
    case Protocol.decode(frame) do
      {:ok, event} -> native(state, event)
      {:error, _error} -> {:noreply, close(state, :protocol_error)}
    end
  end

  def handle_info({handle, {:exit_status, status}}, %{handle: handle} = state),
    do:
      finish(state, if(not is_nil(state.terminal) and status == 0, do: :retired, else: :unknown))

  def handle_info({:EXIT, handle, :normal}, %{handle: handle} = state), do: {:noreply, state}

  def handle_info({:EXIT, handle, _reason}, %{handle: handle} = state),
    do: finish(state, :unknown)

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    if Map.get(state.monitors, monitor) == pid do
      state = %{
        state
        | monitors: Map.delete(state.monitors, monitor),
          manager_lost: state.manager_lost or pid == state.manager
      }

      {:noreply, close(state, :owner_down)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:sweep, %{phase: phase} = state) when phase in [:starting, :ready] do
    now = System.monotonic_time(:millisecond)

    expired =
      (phase == :starting and state.deadline.expires_at <= now) or
        Enum.any?(state.entries, fn {_slot, entry} ->
          entry.status != :retired and entry.expires_at <= now
        end)

    lifetime = Lifetime.status(state.lifetime)

    cond do
      lifetime == %{generation: state.generation, phase: :closing} ->
        {:noreply, close(state, :closure_requested)}

      lifetime != %{generation: state.generation, phase: phase} ->
        {:noreply, close(state, :stale_epoch)}

      expired ->
        {:noreply, close(state, :timeout)}

      true ->
        Process.send_after(self(), :sweep, @sweep_ms)
        {:noreply, state}
    end
  end

  def handle_info({:cleanup_timeout, epoch}, %{epoch: epoch, phase: :closing} = state),
    do: finish(state, :unknown)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.phase != :finished, do: Lifetime.abandon(state.lifetime, state.generation)
    if state.handle, do: state.driver.close(state.handle)
    :ok
  end

  defp native(%{phase: :closing} = state, {:data, _stream, _bytes}), do: {:noreply, state}

  defp native(%{child: nil, phase: :starting} = state, {:started, child}) do
    send_router(state, {:read_credit, state.credit})
    state = %{state | child: child}
    state = native_command(state, Protocol.read_frame(:stderr, 8192))
    {:noreply, grant_stdout(state)}
  end

  defp native(%{stdout_credit: true} = state, {:data, :stdout, bytes}) do
    credit = make_ref()
    send_router(state, {:stdout, bytes, credit})
    {:noreply, %{state | stdout_credit: false, credit: credit}}
  end

  defp native(state, {:data, :stderr, bytes}) do
    count = state.stderr_bytes + byte_size(bytes)
    chunks = state.stderr_chunks + 1

    if count <= 8192 and chunks <= 64 do
      state = %{
        state
        | stderr_bytes: count,
          stderr_chunks: chunks,
          stderr: [bytes | state.stderr]
      }

      {:noreply, native_command(state, Protocol.read_frame(:stderr, 8192))}
    else
      {:noreply, close(state, :resource_limit)}
    end
  end

  defp native(%{phase: :closing} = state, {:written, _id, _bytes, _status}), do: {:noreply, state}

  defp native(%{pending: %{id: id, bytes: count} = pending} = state, {:written, id, count, :ok}) do
    case pending do
      %{kind: :bootstrap} ->
        send_router(state, {:bootstrap_written, state.bootstrap})
        {:noreply, %{state | pending: nil, bootstrap_state: :written}}

      %{kind: :operation, lease: lease, token: token, entry: entry} ->
        cursor = entry.cursor + count
        complete = cursor == entry.total
        entry = %{entry | cursor: cursor, status: if(complete, do: :awaiting, else: :writing)}
        send_router(state, {:written, token, lease, count})

        {:noreply,
         %{
           state
           | pending: nil,
             entries: Map.put(state.entries, lease.slot, entry),
             partial: if(complete, do: nil, else: state.partial)
         }}
    end
  end

  defp native(state, {:terminal, _reason, _status} = proof), do: terminal(state, proof)
  defp native(state, {:failed, _kind, _errno} = proof), do: terminal(state, proof)

  defp native(state, {:warning, :cleanup_incomplete}),
    do: {:noreply, close(state, :cleanup_incomplete)}

  defp native(%{phase: :closing} = state, {:eof, _stream}), do: {:noreply, state}
  defp native(state, {:eof, :stderr}), do: {:noreply, state}
  defp native(state, {:eof, :stdout}), do: {:noreply, close(state, :disconnected)}
  defp native(state, _event), do: {:noreply, close(state, :protocol_error)}

  defp terminal(%{terminal: nil} = state, proof) do
    state = closing(state, :disconnected)
    state = %{state | terminal: proof}

    if state.driver.command(state.handle, Protocol.terminal_ack_frame()),
      do: {:noreply, state},
      else: finish(state, :unknown)
  end

  defp terminal(state, _proof), do: finish(state, :unknown)

  defp grant_stdout(
         %{child: child, stdout_demand: true, stdout_credit: false, phase: phase} = state
       )
       when not is_nil(child) and phase in [:starting, :ready],
       do:
         native_command(
           %{state | stdout_credit: true, stdout_demand: false},
           Protocol.read_frame(:stdout, 8192)
         )

  defp grant_stdout(state), do: state

  defp validate_write(state, token, %Admission.Lease{} = lease, offset, total, bytes) do
    cond do
      not is_reference(token) or node(token) != node() or
        not is_integer(offset) or offset < 0 or not is_integer(total) or total not in 1..65_536 or
        not is_binary(bytes) or byte_size(bytes) not in 1..8192 or
        offset + byte_size(bytes) > total or total > lease.bytes or
        lease.epoch != state.epoch or lease.destination != state.router ->
        rejected(:invalid_write)

      state.pending != nil ->
        rejected(:write_pending)

      state.next_write > 4_294_967_295 ->
        rejected(:resource_limit)

      lease.expires_at <= System.monotonic_time(:millisecond) ->
        rejected(:timeout)

      not line_fragment?(bytes, offset + byte_size(bytes) == total) ->
        rejected(:invalid_write)

      state.partial != nil and state.partial != {lease.slot, lease.generation, token} ->
        rejected(:partial_line_owned)

      true ->
        with :ok <- Admission.verify_consumed(state.pool, lease),
             true <- Lifetime.allows_write?(state.lifetime, state.generation) do
          case Map.get(state.entries, lease.slot) do
            %{
              generation: generation,
              token: ^token,
              cursor: ^offset,
              total: ^total,
              status: :writing
            } = entry
            when generation == lease.generation ->
              {:ok, entry}

            previous when offset == 0 ->
              if is_nil(previous) or previous.generation < lease.generation,
                do:
                  {:ok,
                   %{
                     generation: lease.generation,
                     token: token,
                     cursor: 0,
                     total: total,
                     expires_at: lease.expires_at,
                     status: :writing
                   }},
                else: rejected(:stale_operation)

            _ ->
              rejected(:stale_operation)
          end
        else
          false -> rejected(:stale_epoch)
          error -> error
        end
    end
  end

  defp validate_write(_state, _token, _lease, _offset, _total, _bytes),
    do: rejected(:invalid_write)

  defp line_fragment?(bytes, true),
    do:
      :binary.last(bytes) == 10 and
        :binary.match(binary_part(bytes, 0, byte_size(bytes) - 1), "\n") == :nomatch

  defp line_fragment?(bytes, false), do: :binary.match(bytes, "\n") == :nomatch

  defp write_native(state, id, bytes), do: native_command(state, Protocol.write_frame(id, bytes))

  defp native_command(state, frame) do
    if state.driver.command(state.handle, frame), do: state, else: close(state, :port_busy)
  end

  defp close(%{phase: :closing} = state, _reason), do: state

  defp close(state, reason) do
    state = closing(state, reason)
    if is_nil(state.terminal), do: state.driver.command(state.handle, Protocol.stop_frame())
    state
  end

  defp closing(%{phase: :closing} = state, _reason), do: state

  defp closing(state, reason) do
    Lifetime.revoke(state.lifetime, state.generation)
    error = %Error{kind: reason, phase: :transport, certainty: :unknown}
    notify(state, {:closing, error})
    Process.send_after(self(), {:cleanup_timeout, state.epoch}, @cleanup_ms)
    %{state | phase: :closing, close_reason: error}
  end

  defp finish(state, cleanup) do
    state = closing(state, :disconnected)

    if cleanup == :unknown or state.manager_lost,
      do: Lifetime.abandon(state.lifetime, state.generation)

    notify(
      state,
      {:retired,
       %{
         cleanup: cleanup,
         proof: state.terminal,
         stderr: state.stderr |> Enum.reverse() |> IO.iodata_to_binary(),
         reason: state.close_reason
       }}
    )

    {:stop, :normal, %{state | phase: :finished}}
  end

  defp notify(state, event),
    do:
      Enum.each(
        Enum.uniq([state.manager, state.router]),
        &send(&1, {:guardian, state.epoch, self(), event})
      )

  defp send_router(state, event), do: send(state.router, {:guardian, state.epoch, self(), event})
  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :write, certainty: :no_write}}
end
