defmodule LibTmux.Control.Router do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 950

  alias LibTmux.{Deadline, Error, Protocol}
  alias LibTmux.Control.{Admission, Bootstrap, Request}
  alias LibTmux.Operation.Lifecycle

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    manager = Keyword.fetch!(options, :manager)
    deadline = Keyword.fetch!(options, :deadline)
    Process.send_after(self(), :sweep, 25)

    {:ok,
     %{
       manager: manager,
       manager_monitor: Process.monitor(manager),
       epoch: Keyword.fetch!(options, :epoch),
       pool: Keyword.fetch!(options, :pool),
       records: Keyword.fetch!(options, :records),
       bootstrap_token: Keyword.fetch!(options, :bootstrap),
       bootstrap: Bootstrap.new(deadline),
       deadline: deadline,
       guardian: nil,
       guardian_monitor: nil,
       startup_events: [],
       phase: :starting,
       instance: nil,
       parser:
         Protocol.new(
           max_chunk_bytes: 8192,
           max_line_bytes: 65_536,
           max_frame_bytes: 65_536,
           max_frame_lines: 1024,
           max_events: 128
         ),
       startup_bytes: 0,
       last_number: -1,
       operations: %{},
       queue: :queue.new(),
       replies: :queue.new(),
       writer: nil,
       close_reason: nil
     }}
  end

  @impl true
  def handle_info(
        {:bind, manager, epoch, guardian},
        %{manager: manager, epoch: epoch, guardian: nil} = state
      )
      when is_pid(guardian) do
    state = %{state | guardian: guardian, guardian_monitor: Process.monitor(guardian)}
    if state.phase == :closing, do: send_guardian(state, {:close, self(), epoch, :startup_closed})

    next =
      Enum.reduce(Enum.reverse(state.startup_events), %{state | startup_events: []}, fn
        {^guardian, event}, state -> guardian_event(state, event)
        _foreign, state -> close_epoch(state, :stale_epoch)
      end)

    {:noreply, next}
  end

  def handle_info({:guardian, epoch, guardian, event}, %{epoch: epoch, guardian: nil} = state) do
    if length(state.startup_events) < 4,
      do: {:noreply, %{state | startup_events: [{guardian, event} | state.startup_events]}},
      else: {:noreply, close_epoch(state, :startup_overload)}
  end

  def handle_info(
        {:guardian, epoch, guardian, {:retired, proof}},
        %{epoch: epoch, guardian: guardian} = state
      ),
      do: retire(state, proof)

  def handle_info(
        {:guardian, epoch, guardian, event},
        %{epoch: epoch, guardian: guardian} = state
      ),
      do: {:noreply, guardian_event(state, event)}

  def handle_info(
        {:submit, epoch, %Admission.Lease{} = lease, %Request{} = request},
        %{epoch: epoch, phase: :ready} = state
      ) do
    with {:ok, line} <- Request.encode(request, state.instance),
         true <- byte_size(line) <= lease.bytes,
         true <- lease.epoch == epoch and lease.destination == self(),
         :ok <- Admission.consume(state.pool, lease, byte_size(line)) do
      token = make_ref()
      life = Lifecycle.new(epoch, token, %Deadline{expires_at: lease.expires_at}, byte_size(line))

      entry = %{
        lease: lease,
        token: token,
        life: life,
        line: line,
        request: request,
        reply: nil,
        sent_until: 0,
        wire_requested: false
      }

      state = store(state, entry)
      {:noreply, dispatch(%{state | queue: :queue.in({lease.slot, token}, state.queue)})}
    else
      {:error, error} -> {:noreply, close_epoch(state, error.kind)}
      false -> {:noreply, close_epoch(state, :invalid_publication)}
    end
  end

  def handle_info({:submit, _epoch, _lease, _request}, state),
    do: {:noreply, close_epoch(state, :invalid_publication)}

  def handle_info(:sweep, %{phase: phase} = state) when phase in [:starting, :ready] do
    state =
      cond do
        phase == :starting and Deadline.remaining(state.deadline) == 0 ->
          close_epoch(state, :timeout)

        phase == :ready ->
          expire_operations(state)

        true ->
          state
      end

    if state.phase in [:starting, :ready], do: Process.send_after(self(), :sweep, 25)
    {:noreply, dispatch(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{manager_monitor: monitor} = state),
    do: {:stop, :normal, close_epoch(state, :owner_down)}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{guardian_monitor: monitor} = state
      ),
      do: retire(state, %{cleanup: :unknown, reason: :guardian_down})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{phase: :retired}), do: :ok

  def terminate(_reason, state) do
    send_guardian(state, {:close, self(), state.epoch, :router_down})
    :ok
  end

  defp guardian_event(%{phase: :starting} = state, {:read_credit, credit}) do
    send_guardian(state, {:read, self(), state.epoch, credit})
    state
  end

  defp guardian_event(state, {:stdout, bytes, credit}) when state.phase in [:starting, :ready] do
    state =
      if state.phase == :starting and state.startup_bytes + byte_size(bytes) > 65_536 do
        close_epoch(state, :resource_limit)
      else
        case Protocol.feed(state.parser, bytes) do
          {:ok, events, parser} ->
            state = %{
              state
              | parser: parser,
                startup_bytes:
                  if(state.phase == :starting,
                    do: state.startup_bytes + byte_size(bytes),
                    else: state.startup_bytes
                  )
            }

            Enum.reduce(events, state, &event(&2, &1))

          {:error, error} ->
            state = Enum.reduce(error.details.events, state, &event(&2, &1))
            close_epoch(state, error.kind)
        end
      end

    if state.phase in [:starting, :ready],
      do: send_guardian(state, {:read, self(), state.epoch, credit})

    state
  end

  defp guardian_event(%{phase: :starting} = state, {:bootstrap_written, token})
       when token == state.bootstrap_token, do: bootstrap_event(state, :written)

  defp guardian_event(%{phase: :starting} = state, :active) do
    case Bootstrap.identity(state.bootstrap) do
      {:ok, instance} ->
        notify(state, {:ready, instance})
        %{state | phase: :ready, instance: instance}

      {:error, error} ->
        close_epoch(state, error.kind)
    end
  end

  defp guardian_event(%{phase: :ready} = state, {:written, token, lease, count}) do
    case Map.get(state.operations, lease.slot) do
      %{token: ^token, lease: ^lease} = entry when state.writer == lease.slot ->
        case Lifecycle.step(entry.life, {:owner, state.epoch, token, {:written, count}}) do
          {:ok, life, actions} ->
            state = store(state, %{entry | life: life}) |> actions(actions)

            if state.phase == :ready do
              if life.wire == :awaiting do
                state = accept_pending_reply(state, lease.slot)
                dispatch(%{state | writer: nil})
              else
                fragment(state, Map.fetch!(state.operations, lease.slot))
              end
            else
              state
            end

          {:error, error} ->
            close_epoch(state, error.kind)
        end

      _ ->
        close_epoch(state, :stale_operation)
    end
  end

  defp guardian_event(%{phase: :ready} = state, {:wire_retired, token, lease}) do
    case Map.get(state.operations, lease.slot) do
      %{token: ^token, lease: ^lease} = entry ->
        case Lifecycle.step(entry.life, {:owner, state.epoch, token, :retire}) do
          {:ok, life, actions} ->
            store(state, %{entry | life: life}) |> actions(actions) |> finish_entry(lease.slot)

          {:error, error} ->
            close_epoch(state, error.kind)
        end

      _ ->
        close_epoch(state, :stale_operation)
    end
  end

  defp guardian_event(state, {:closing, error}), do: close_epoch(state, error.kind)
  defp guardian_event(%{phase: :closing} = state, _event), do: state
  defp guardian_event(state, _event), do: close_epoch(state, :protocol_error)

  defp event(%{phase: :closing} = state, _event), do: state

  defp event(state, {:reply, _status, {_, number, _}, _lines} = reply) do
    if number > state.last_number,
      do: reply(%{state | last_number: number}, reply),
      else: close_epoch(state, :reply_order)
  end

  defp event(%{phase: :starting} = state, notification), do: bootstrap_event(state, notification)

  defp event(state, {:notification, name, _payload})
       when name in [
              :exit,
              :config_error,
              :message,
              :subscription_changed,
              :output,
              :extended_output
            ],
       do: close_epoch(state, :unqualified_notification)

  defp event(state, {:notification, _name, _payload}), do: state
  defp event(state, _event), do: close_epoch(state, :protocol_error)

  defp reply(%{phase: :starting} = state, reply), do: bootstrap_event(state, reply)

  defp reply(state, {:reply, status, {_, _, 1} = guard, lines}) do
    case :queue.out(state.replies) do
      {{:value, {slot, token}}, rest} ->
        case Map.get(state.operations, slot) do
          %{token: ^token, reply: nil} = entry when entry.sent_until == byte_size(entry.line) ->
            case Request.verify_reply(entry.request, status, lines) do
              :ok ->
                observation = %{
                  status: status,
                  guard: guard,
                  lines: lines,
                  observed_at: System.monotonic_time(:millisecond)
                }

                case Lifecycle.step(
                       entry.life,
                       {:owner, state.epoch, token, {:reply, status, guard, lines}},
                       now: observation.observed_at
                     ) do
                  {:ok, life, actions} ->
                    state =
                      store(%{state | replies: rest}, %{entry | life: life, reply: observation})
                      |> actions(actions)

                    if state.phase == :ready, do: accept_pending_reply(state, slot), else: state

                  {:error, error} ->
                    close_epoch(state, error.kind)
                end

              {:error, error} ->
                close_epoch(state, error.kind)
            end

          _ ->
            close_epoch(state, :stale_operation)
        end

      {:empty, _} ->
        close_epoch(state, :unexpected_reply)
    end
  end

  defp reply(state, _reply), do: close_epoch(state, :invalid_reply)

  defp bootstrap_event(state, event) do
    case Bootstrap.event(state.bootstrap, event) do
      {:ok, bootstrap, actions} ->
        Enum.reduce(actions, %{state | bootstrap: bootstrap}, fn
          {:identity, _pid}, state ->
            case Bootstrap.identify(state.bootstrap) do
              {:ok, bootstrap, nonce} ->
                state = %{state | bootstrap: bootstrap}

                send_guardian(
                  state,
                  {:challenge, self(), state.epoch, state.bootstrap_token, nonce}
                )

                state

              {:error, error} ->
                close_epoch(state, error.kind)
            end

          :activate, state ->
            send_guardian(state, {:activate, self(), state.epoch, state.bootstrap_token})
            state
        end)

      {:error, error} ->
        close_epoch(state, error.kind)
    end
  end

  defp dispatch(%{phase: :ready, writer: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {slot, token}}, queue} ->
        state = %{state | queue: queue}

        case Map.get(state.operations, slot) do
          %{token: ^token} = entry ->
            case Lifecycle.step(entry.life, {:owner, state.epoch, entry.token, :dispatch}) do
              {:ok, life, actions} ->
                state = store(state, %{entry | life: life}) |> actions(actions)

                if Lifecycle.wire_retired?(life) do
                  state |> finish_entry(slot) |> dispatch()
                else
                  state = %{
                    state
                    | writer: slot,
                      replies: :queue.in({slot, entry.token}, state.replies)
                  }

                  fragment(state, Map.fetch!(state.operations, slot))
                end

              {:error, error} ->
                close_epoch(state, error.kind)
            end

          _stale ->
            dispatch(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp fragment(%{phase: :ready} = state, entry) do
    offset = entry.life.written
    bytes = binary_part(entry.line, offset, min(byte_size(entry.line) - offset, 8192))
    state = store(state, %{entry | sent_until: offset + byte_size(bytes)})

    send_guardian(
      state,
      {:write, self(), state.epoch, entry.token, entry.lease, offset, byte_size(entry.line),
       bytes}
    )

    state
  end

  defp accept_pending_reply(state, slot) do
    case Map.fetch!(state.operations, slot) do
      %{life: %{wire: :awaiting, result: result}, wire_requested: false} = entry
      when not is_nil(result) ->
        state = store(state, %{entry | wire_requested: true})
        send_guardian(state, {:wire_retired, self(), state.epoch, entry.token, entry.lease})
        state

      _ ->
        state
    end
  end

  defp expire_operations(state) do
    Enum.reduce(Map.keys(state.operations), state, fn slot, state ->
      entry = Map.fetch!(state.operations, slot)

      if Deadline.remaining(entry.life.deadline) == 0 do
        case Lifecycle.step(entry.life, :expire) do
          {:ok, life, actions} ->
            state = store(state, %{entry | life: life}) |> actions(actions)
            if Lifecycle.wire_retired?(life), do: finish_entry(state, slot), else: state

          {:error, error} ->
            close_epoch(state, error.kind)
        end
      else
        state
      end
    end)
  end

  defp actions(state, actions) do
    if :close_epoch in actions, do: close_epoch(state, :timeout), else: state
  end

  defp store(state, entry) do
    # Register before the first byte; records retain no command payload or closure.
    true =
      :ets.insert(
        state.records,
        {entry.lease.slot, Map.take(entry, [:lease, :token, :life, :reply])}
      )

    %{state | operations: Map.put(state.operations, entry.lease.slot, entry)}
  end

  defp finish_entry(state, slot) do
    entry = Map.fetch!(state.operations, slot)

    if Lifecycle.wire_retired?(entry.life) do
      queue = :queue.filter(&(&1 != {slot, entry.token}), state.queue)
      notify(state, {:settled, entry.lease})
      %{state | operations: Map.delete(state.operations, slot), queue: queue}
    else
      state
    end
  end

  defp retire(state, proof) do
    state =
      Enum.reduce(Map.keys(state.operations), state, fn slot, state ->
        entry = Map.fetch!(state.operations, slot)
        {:ok, life, _actions} = Lifecycle.step(entry.life, {:epoch_closed, state.epoch})
        store(state, %{entry | life: life}) |> finish_entry(slot)
      end)

    notify(state, {:retired, proof})
    {:stop, :normal, %{state | phase: :retired}}
  end

  defp close_epoch(%{phase: :closing} = state, _kind), do: state

  defp close_epoch(state, kind) do
    error = %Error{kind: kind, phase: :operation, certainty: :unknown}
    send_guardian(state, {:close, self(), state.epoch, kind})
    notify(state, {:closing, error})
    %{state | phase: :closing, close_reason: error}
  end

  defp send_guardian(%{guardian: nil}, _message), do: :ok
  defp send_guardian(state, message), do: send(state.guardian, message)
  defp notify(state, event), do: send(state.manager, {:router, state.epoch, self(), event})
end
