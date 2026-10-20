defmodule LibTmux.Control.Manager do
  @moduledoc false
  use GenServer, shutdown: 950

  alias LibTmux.{Deadline, Error}

  alias LibTmux.Control.{
    Admission,
    Births,
    EpochSupervisor,
    Guardian,
    Inbox,
    Lifetime,
    Records,
    Router,
    Waiters
  }

  alias LibTmux.Transport.Native.Driver
  @cleanup_ms 800

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    options =
      Keyword.validate!(options, [
        :host,
        :view,
        :lifetime,
        :deadline,
        :payload,
        driver: {Driver, []},
        capacity: 32,
        metadata_capacity: 32,
        waiter_capacity: 32,
        retention_ms: 60_000
      ])

    lifetime = Keyword.fetch!(options, :lifetime)
    %{generation: generation, phase: phase} = Lifetime.status(lifetime)
    pool = Admission.new(options[:capacity])
    records = Records.new(pool)
    inbox = Inbox.new(options[:metadata_capacity], kinds: [:reconnect, :forget])
    waiters = Waiters.new(records, options[:waiter_capacity])
    payload = Keyword.fetch!(options, :payload)
    retention = options[:retention_ms]

    unless is_binary(payload) and byte_size(payload) <= 32_768 and
             is_integer(retention) and retention in 1..600_000,
           do: raise(ArgumentError, "invalid bounded startup payload or retention")

    host = Keyword.fetch!(options, :host)

    unless is_pid(host) and node(host) == node(),
      do: raise(ArgumentError, "host must be a local PID")

    state = %{
      host: host,
      host_monitor: Process.monitor(host),
      view: Keyword.fetch!(options, :view),
      lifetime: lifetime,
      generation: generation,
      epoch: make_ref(),
      pool: pool,
      records: records,
      inbox: inbox,
      waiters: waiters,
      payload: :binary.copy(payload),
      driver: options[:driver],
      retention_ms: retention,
      phase: if(phase == :retired, do: :closed, else: :unknown),
      births: nil,
      pending: nil,
      actors: %{epoch_supervisor: nil, router: nil, guardian: nil},
      monitors: %{},
      dead: MapSet.new(),
      deadline: Keyword.fetch!(options, :deadline),
      bootstrap: nil,
      instance: nil,
      native_retired: false,
      host_finalized: false,
      bound: false,
      router_stop_requested: false,
      unclean: phase != :retired,
      closing_at: nil,
      waiting: [],
      reason: nil
    }

    state =
      if generation == 0 and phase == :retired do
        begin_start(state, state.deadline, true)
      else
        if phase != :retired, do: abandon(lifetime, generation)
        state
      end

    Process.send_after(self(), :sweep, 25)
    {:ok, publish(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = harvest(state)
    {:ok, _count} = Inbox.reap(state.inbox)
    state = requests(state)
    state = account(state) |> service_waiters() |> progress() |> publish()
    Process.send_after(self(), :sweep, 25)
    {:noreply, state}
  end

  def handle_info({Inbox, :wake, table, generation}, state) when table == state.inbox.table do
    Inbox.consume_wake(state.inbox, {self(), table, generation})
    {:noreply, state |> harvest() |> requests() |> service_waiters() |> progress() |> publish()}
  end

  def handle_info({Inbox, :wake, table, generation}, state)
      when table == state.waiters.inbox.table do
    Inbox.consume_wake(state.waiters.inbox, {self(), table, generation})
    {:noreply, state |> service_waiters() |> progress() |> publish()}
  end

  def handle_info(message, state) do
    state = service_waiters(state) |> harvest()

    state =
      case state.pending do
        nil ->
          actor_event(state, message)

        pending ->
          case :gen_server.check_response(message, pending.id) do
            :no_reply -> actor_event(state, message)
            response -> supervisor_response(%{state | pending: nil}, pending.kind, response)
          end
      end

    {:noreply, state |> service_waiters() |> progress() |> publish()}
  end

  @impl true
  def terminate(_reason, state) do
    if state.births, do: Births.close(state.births)
    if state.phase != :closed, do: abandon(state.lifetime, state.generation)
    if state.pending, do: :gen_server.receive_response(state.pending.id, 0)
    :ok
  end

  defp begin_start(state, deadline, initial \\ false) do
    case Lifetime.begin_epoch(state.lifetime) do
      {:ok, generation} ->
        epoch = if initial, do: state.epoch, else: make_ref()
        births = Births.new(state.lifetime, generation, epoch, deadline)

        state = %{
          state
          | generation: generation,
            epoch: epoch,
            births: births,
            deadline: deadline,
            bootstrap: make_ref(),
            instance: nil,
            phase: :starting,
            native_retired: false,
            host_finalized: false,
            bound: false,
            router_stop_requested: false,
            unclean: false,
            closing_at: nil,
            reason: nil,
            actors: %{epoch_supervisor: nil, router: nil, guardian: nil},
            monitors: %{},
            dead: MapSet.new()
        }

        request(state, :epoch, state.host, {:start_child, EpochSupervisor.child_spec(births)})

      {:error, error} ->
        fail_waiters(%{state | phase: :unknown, unclean: true}, error.kind)
    end
  end

  defp request(%{pending: nil} = state, kind, target, payload) do
    id = :gen_server.send_request(target, payload)
    %{state | pending: %{id: id, kind: kind, target: target}}
  end

  defp supervisor_response(%{phase: :starting} = state, kind, {:reply, {:ok, pid}}) do
    role =
      case kind do
        :epoch -> :epoch_supervisor
        :router -> :router
        :guardian -> :guardian
      end

    if state.actors[role] == pid and Deadline.remaining(state.deadline) > 0 and
         Lifetime.status(state.lifetime) == %{generation: state.generation, phase: :starting} do
      common = [
        manager: self(),
        epoch: state.epoch,
        deadline: state.deadline,
        births: state.births,
        pool: state.pool,
        records: state.records.table,
        bootstrap: state.bootstrap
      ]

      case kind do
        :epoch ->
          request(
            state,
            :router,
            pid,
            {:start_child, Supervisor.child_spec({Router, common}, [])}
          )

        :router ->
          options =
            common ++
              [
                router: pid,
                lifetime: state.lifetime,
                generation: state.generation,
                payload: state.payload,
                driver: state.driver
              ]

          request(
            state,
            :guardian,
            state.actors.epoch_supervisor,
            {:start_child, Supervisor.child_spec({Guardian, options}, [])}
          )

        :guardian ->
          bind(state)
      end
    else
      close(state, :startup_closed)
    end
  end

  defp supervisor_response(state, :finalize, {:reply, reply})
       when reply in [:ok, {:error, :not_found}],
       do: %{state | host_finalized: true}

  defp supervisor_response(state, :finalize, _response), do: poison(state)

  defp supervisor_response(state, _kind, _response) when state.phase in [:closing, :unknown],
    do: state

  defp supervisor_response(state, _kind, _response), do: close(state, :startup_failed)

  defp harvest(%{births: nil} = state), do: state

  defp harvest(state) do
    case Births.snapshot(state.births) do
      {:ok, %{roles: roles}} ->
        Enum.reduce(roles, state, fn
          {_role, nil}, state ->
            state

          {role, pid}, state ->
            if state.actors[role] == pid do
              state
            else
              monitor = Process.monitor(pid)

              %{
                state
                | actors: Map.put(state.actors, role, pid),
                  monitors: Map.put(state.monitors, monitor, {role, pid})
              }
            end
        end)

      {:error, _error} ->
        poison(state)
    end
  end

  defp actor_event(state, {:router, epoch, router, {:ready, instance}})
       when epoch == state.epoch and router == state.actors.router and state.phase == :starting do
    if Deadline.remaining(state.deadline) > 0 and
         Lifetime.allows_write?(state.lifetime, state.generation) do
      state = %{state | phase: :ready, instance: instance}
      Enum.each(state.waiting, &connected(state, &1))
      %{state | waiting: []}
    else
      close(state, :timeout)
    end
  end

  defp actor_event(state, {:guardian, epoch, guardian, {:retired, proof}})
       when epoch == state.epoch and guardian == state.actors.guardian do
    state = close(state, :disconnected)

    if proof.cleanup == :retired and not is_nil(proof.proof),
      do: %{state | native_retired: true},
      else: poison(state)
  end

  defp actor_event(state, {:guardian, epoch, guardian, {:closing, error}})
       when epoch == state.epoch and guardian == state.actors.guardian,
       do: close(state, error.kind)

  defp actor_event(state, {:router, epoch, router, {:closing, error}})
       when epoch == state.epoch and router == state.actors.router, do: close(state, error.kind)

  defp actor_event(state, {:DOWN, monitor, :process, _pid, _reason})
       when monitor == state.host_monitor,
       do: state |> close(:host_down) |> poison()

  defp actor_event(state, {:DOWN, monitor, :process, pid, _reason}) do
    case Map.get(state.monitors, monitor) do
      {role, ^pid} ->
        state = %{
          state
          | dead: MapSet.put(state.dead, role),
            monitors: Map.delete(state.monitors, monitor)
        }

        if role == :router, do: Records.finalize(state.records, state.epoch, pid)
        state = if state.phase in [:starting, :ready], do: close(state, :actor_down), else: state
        if role == :guardian and not state.native_retired, do: poison(state), else: state

      _ ->
        state
    end
  end

  defp actor_event(state, _message), do: state

  defp close(%{phase: phase} = state, _kind) when phase in [:closing, :unknown], do: state
  defp close(%{phase: :closed} = state, _kind), do: state

  defp close(state, kind) do
    if state.births, do: Births.close(state.births)
    Lifetime.revoke(state.lifetime, state.generation)

    state =
      %{
        state
        | phase: :closing,
          reason: kind,
          closing_at: System.monotonic_time(:millisecond) + @cleanup_ms
      }
      |> harvest()

    state =
      if state.pending do
        pending = state.pending
        response = :gen_server.receive_response(pending.id, 0)
        state = %{state | pending: nil}

        case response do
          :timeout -> poison(state)
          response -> supervisor_response(state, pending.kind, response)
        end
      else
        state
      end

    fail_waiters(state, if(state.unclean, do: :cleanup_unknown, else: kind))
  end

  defp poison(state) do
    abandon(state.lifetime, state.generation)
    fail_waiters(%{state | unclean: true, phase: :unknown}, :cleanup_unknown)
  end

  defp abandon(lifetime, 0), do: Lifetime.abandon_initial(lifetime)
  defp abandon(lifetime, generation), do: Lifetime.abandon(lifetime, generation)

  defp progress(%{phase: phase} = state) when phase in [:closing, :unknown] do
    state = harvest(state) |> stop_startup()
    children_gone = gone?(state, :router) and gone?(state, :guardian)

    cond do
      state.unclean and children_gone ->
        if state.actors.epoch_supervisor && not gone?(state, :epoch_supervisor),
          do: Process.exit(state.actors.epoch_supervisor, :kill)

        state

      state.pending == nil and children_gone and
        (state.native_retired or is_nil(state.actors.guardian)) and not state.host_finalized ->
        request(state, :finalize, state.host, {:terminate_child, :epoch})

      state.host_finalized and children_gone and gone?(state, :epoch_supervisor) ->
        case Lifetime.retired(state.lifetime, state.generation) do
          :ok ->
            if state.births, do: :ets.delete(state.births.table)
            %{state | phase: :closed, births: nil, closing_at: nil}

          {:error, _error} ->
            poison(state)
        end

      true ->
        state
    end
  end

  defp progress(%{phase: :closed, waiting: [_ | _]} = state) do
    {expired, active} =
      Enum.split_with(
        state.waiting,
        &(Deadline.remaining(%Deadline{expires_at: &1.expires_at}) == 0)
      )

    Enum.each(expired, &Inbox.finish(state.inbox, &1, failure(:timeout)))
    state = %{state | waiting: active}

    if active == [],
      do: state,
      else: begin_start(state, %Deadline{expires_at: List.last(active).expires_at})
  end

  defp progress(state), do: state
  defp gone?(state, role), do: is_nil(state.actors[role]) or MapSet.member?(state.dead, role)

  defp bind(%{bound: true} = state), do: state

  defp bind(state) do
    if is_pid(state.actors.router) and is_pid(state.actors.guardian) do
      send(state.actors.router, {:bind, self(), state.epoch, state.actors.guardian})
      %{state | bound: true}
    else
      state
    end
  end

  defp stop_startup(state) do
    state = bind(state)

    # The closed Births gate excludes a later Guardian and native startup.
    if is_nil(state.actors.guardian) and not gone?(state, :router) and
         not state.router_stop_requested do
      Process.exit(state.actors.router, :kill)
      %{state | router_stop_requested: true}
    else
      state
    end
  end

  defp account(state) do
    now = System.monotonic_time(:millisecond)

    state = observe_gate(state)

    state =
      if state.phase == :starting and Deadline.remaining(state.deadline) == 0,
        do: close(state, :timeout),
        else: state

    state =
      if state.closing_at && state.closing_at <= now do
        state = poison(state)

        for role <- [:router, :guardian, :epoch_supervisor],
            pid = state.actors[role],
            is_pid(pid) and not gone?(state, role),
            do: Process.exit(pid, :kill)

        %{state | closing_at: nil}
      else
        state
      end

    {:ok, entries} = Admission.entries(state.pool)

    Enum.each(
      Enum.uniq(
        for {_status, lease} <- entries,
            not Process.alive?(lease.destination),
            do: {lease.epoch, lease.destination}
      ),
      fn {epoch, destination} ->
        Records.finalize(state.records, epoch, destination)
      end
    )

    state =
      Enum.reduce(entries, state, fn {_status, lease}, state ->
        if lease.expires_at + state.retention_ms <= now do
          {waiters, _outcome} = Waiters.forget(state.waiters, lease)
          %{state | waiters: waiters}
        else
          state
        end
      end)

    expired_publication =
      Enum.any?(entries, fn {status, lease} ->
        status == :reserved and lease.epoch == state.epoch and lease.expires_at <= now
      end)

    state = if expired_publication, do: close(state, :timeout), else: state

    Enum.each(state.waiting, fn ticket ->
      if ticket.expires_at <= now, do: Inbox.finish(state.inbox, ticket, failure(:timeout))
    end)

    %{state | waiting: Enum.reject(state.waiting, &(&1.expires_at <= now))}
  end

  defp requests(state) do
    state = service_waiters(state) |> observe_gate()
    {:ok, work} = Inbox.take(state.inbox)

    Enum.reduce(work, state, fn
      {ticket, {:reconnect, nil}}, state ->
        reconnect(state, ticket)

      {ticket, {:forget, lease}}, state ->
        {waiters, outcome} =
          if ticket.epoch == lease.epoch,
            do: Waiters.forget(state.waiters, lease),
            else: {state.waiters, failure(:stale_epoch)}

        Inbox.finish(state.inbox, ticket, outcome)
        %{state | waiters: waiters}
    end)
  end

  defp observe_gate(%{phase: phase} = state) when phase in [:starting, :ready] do
    observed = Lifetime.status(state.lifetime)
    allowed = if phase == :starting, do: [:starting, :ready], else: [:ready]

    if observed.generation == state.generation and observed.phase in allowed,
      do: state,
      else: close(state, :closure_requested)
  end

  defp observe_gate(state), do: state

  defp reconnect(state, ticket) do
    cond do
      state.unclean ->
        Inbox.finish(state.inbox, ticket, failure(:cleanup_unknown))
        state

      ticket.epoch != state.epoch ->
        Inbox.finish(state.inbox, ticket, failure(:stale_epoch))
        state

      state.phase == :ready ->
        connected(state, ticket)
        state

      state.phase == :starting ->
        %{state | waiting: [ticket | state.waiting]}

      state.phase == :closing ->
        %{state | waiting: [ticket | state.waiting]}

      state.phase == :closed ->
        begin_start(%{state | waiting: [ticket | state.waiting]}, %Deadline{
          expires_at: ticket.expires_at
        })
    end
  end

  defp fail_waiters(state, kind) do
    Enum.each(state.waiting, &Inbox.finish(state.inbox, &1, failure(kind)))
    %{state | waiting: []}
  end

  defp service_waiters(state) do
    waiters = Waiters.turn(state.waiters)
    state = %{state | waiters: waiters}

    if waiters.fault && state.phase != :unknown,
      do: state |> close(:waiter_failed) |> poison(),
      else: state
  end

  defp connected(state, ticket) do
    Inbox.finish(state.inbox, ticket, {:ok, endpoint(state)},
      references: [
        state.epoch,
        state.lifetime.word,
        state.pool.table,
        state.records.table,
        state.births.table,
        state.waiters.inbox.table,
        state.waiters.inbox.wake,
        state.waiters.inbox.receipts
      ]
    )
  end

  defp endpoint(state),
    do:
      Map.take(state, [
        :phase,
        :epoch,
        :generation,
        :lifetime,
        :pool,
        :records,
        :inbox,
        :instance,
        :births
      ])
      |> Map.merge(%{
        manager: self(),
        router: state.actors.router,
        waiter_inbox: state.waiters.inbox
      })

  defp publish(state) do
    :ets.insert(state.view, {:connection, endpoint(state)})
    state
  end

  defp failure(kind), do: {:error, %Error{kind: kind, phase: :connect, certainty: :unknown}}
end
