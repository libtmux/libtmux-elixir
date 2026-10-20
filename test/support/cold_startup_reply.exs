defmodule LibTmux.Test.ColdReplyGate do
  def init({observer, token}) do
    send(observer, {token, :initializing, self()})

    receive do
      {^token, :continue} -> {:ok, {%{strategy: :one_for_one}, []}}
    end
  end
end

defmodule LibTmux.Test.ColdReplyProbe do
  alias LibTmux.Control.{ConnectionSupervisor, EpochHost, Lifetime, SupervisorStart}
  alias LibTmux.{Deadline, Transport.Reply}

  def run(mode) do
    Enum.each(
      [Supervisor, SupervisorStart, ConnectionSupervisor, Lifetime, Deadline, JSON],
      &Code.ensure_loaded!/1
    )

    if mode == :connection, do: false = :code.is_loaded(EpochHost)
    lifetime = Lifetime.new()
    false = :code.is_loaded(Reply)
    observer = self()
    token = make_ref()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        receive do
          {^token, :start} -> :ok
        end

        result =
          case mode do
            :supervisor ->
              SupervisorStart.start_link(
                LibTmux.Test.ColdReplyGate,
                {observer, token},
                Deadline.new(25)
              )

            :connection ->
              ConnectionSupervisor.start_link(
                deadline: Deadline.new(25),
                payload: <<0>>,
                lifetime: lifetime,
                capacity: 1,
                metadata_capacity: 1,
                waiter_capacity: 1,
                retention_ms: 100
              )
          end

        send(
          observer,
          {token, :returned, result, Process.info(self(), :monitors),
           Process.info(self(), :links)}
        )

        receive do
          {^token, :finish} -> :ok
        end
      end)

    if mode == :connection,
      do: 1 = :erlang.trace(caller, true, [:procs, {:tracer, self()}])

    code_server = Process.whereis(:code_server)
    true = :erlang.suspend_process(code_server)
    observation = Deadline.new(100)

    captured =
      try do
        send(caller, {token, :start})

        root =
          receive do
            {^token, :initializing, root} when mode == :supervisor -> root
            {:trace, ^caller, :spawn, root, _entry} when mode == :connection -> root
          after
            Deadline.remaining(observation) -> :erlang.error(:root_entry_not_observed)
          end

        root_monitor = Process.monitor(root)

        receive do
          {:DOWN, ^root_monitor, :process, ^root, :killed} -> :ok
        after
          Deadline.remaining(observation) -> :erlang.error(:root_exit_not_observed)
        end

        returned =
          receive do
            {^token, :returned, result, monitors, links} -> {result, monitors, links}
          after
            Deadline.remaining(observation) -> :missed_original_observation
          end

        timely = returned != :missed_original_observation and Deadline.remaining(observation) > 0
        {:messages, loader_messages} = Process.info(code_server, :messages)

        root_gate =
          mode == :supervisor or
            Enum.member?(
              loader_messages,
              {:code_call, root, {:get_object_code_for_loading, EpochHost}}
            )

        if not root_gate, do: :erlang.error(:root_loader_gate_not_observed)

        %{
          root: root,
          returned: returned,
          timely: timely,
          caller_function: Process.info(caller, :current_function),
          caller_status: Process.info(caller, :status),
          loader_messages: loader_messages,
          root_gate: root_gate,
          code_server_status: Process.info(code_server, :status),
          reply_loaded: :code.is_loaded(Reply)
        }
      after
        true = :erlang.resume_process(code_server)
      end

    final =
      case captured.returned do
        :missed_original_observation ->
          receive do
            {^token, :returned, result, monitors, links} -> {result, monitors, links}
          after
            500 -> raise "caller did not return after isolated loader release"
          end

        returned ->
          returned
      end

    send(caller, {token, :finish})

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, :normal} -> :ok
    after
      500 -> raise "exact caller exit was not observed"
    end

    false = Process.alive?(captured.root)
    false = Process.alive?(caller)
    {{:error, :timeout}, {:monitors, []}, {:links, []}} = final

    output = %{
      "status" => if(captured.timely, do: "PASS", else: "FAIL"),
      "scope" => "Cold Reply cleanup after actual Root exit in a disposable VM",
      "entry" => Atom.to_string(mode),
      "operation_ms" => 25,
      "observation_ms" => 100,
      "root_exit" => "killed",
      "caller_exit" => "normal",
      "reply_loaded_during_gate" => captured.reply_loaded != false,
      "code_server_suspended" => captured.code_server_status == {:status, :suspended},
      "root_gate_confirmed" => captured.root_gate,
      "return_observed_in_budget" => captured.timely,
      "caller_function" => inspect(captured.caller_function),
      "caller_status" => inspect(captured.caller_status),
      "code_server_status" => inspect(captured.code_server_status),
      "loader_messages" => inspect(captured.loader_messages, limit: 32, printable_limit: 4096),
      "caller_after_resume" => inspect(final)
    }

    IO.puts(JSON.encode!(output))
    if output["status"] == "FAIL", do: System.halt(2)
  end
end

mode =
  case System.argv() do
    ["supervisor"] -> :supervisor
    ["connection"] -> :connection
  end

LibTmux.Test.ColdReplyProbe.run(mode)
