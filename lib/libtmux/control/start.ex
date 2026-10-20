defmodule LibTmux.Control.Start do
  @moduledoc false
  alias LibTmux.{Control, Deadline, Error, Server}
  alias LibTmux.Control.{Bootstrap, ConnectionSupervisor, Lifetime}
  alias LibTmux.Transport.Native.Protocol

  @enforce_keys [:options, :timeout]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  def child_spec(options) do
    prepared = prepare(options)

    %{
      id: Control,
      start: {__MODULE__, :start_link, [prepared]},
      restart: :permanent,
      type: :supervisor,
      shutdown: 950
    }
  end

  def start(options, entered_at), do: open(prepare(options), entered_at)

  def start_link(%__MODULE__{} = prepared),
    do: open(prepared, System.monotonic_time(:millisecond))

  defp prepare(options) do
    options =
      Keyword.validate!(options, [
        :server,
        :session,
        :lane,
        timeout: 5000,
        capacity: 32,
        metadata_capacity: 32,
        waiter_capacity: 32,
        retention_ms: 60_000
      ])

    unless match?(%Server{}, options[:server]) and
             match?({:existing, session} when is_binary(session), options[:session]) and
             options[:lane] == :host_qualified,
           do:
             raise(
               ArgumentError,
               "control requires an explicit Server, existing session ID and host-qualified lane"
             )

    server = options[:server]
    {:existing, session} = options[:session]

    unless is_binary(server.socket) and Path.type(server.socket) == :absolute and
             byte_size(server.socket) in 1..32_000 and
             :binary.match(server.socket, <<0>>) == :nomatch,
           do: raise(ArgumentError, "control requires an absolute bounded NUL-free socket")

    timeout = options[:timeout]
    deadline(timeout, System.monotonic_time(:millisecond))

    payload =
      Protocol.process(server.executable, Bootstrap.arguments(server, session),
        cwd: server.cwd,
        env: server.env
      )

    settings =
      Keyword.take(options, [:capacity, :metadata_capacity, :waiter_capacity, :retention_ms])

    %{start: {ConnectionSupervisor, :start_link, [root_options]}} =
      ConnectionSupervisor.child_spec(
        settings ++ [deadline: %Deadline{expires_at: 0}, payload: payload]
      )

    %__MODULE__{options: Keyword.delete(root_options, :deadline), timeout: timeout}
  end

  defp open(prepared, entered_at) do
    deadline = deadline(prepared.timeout, entered_at)
    lifetime = prepared.options[:lifetime]
    initial = Lifetime.status(lifetime)
    options = Keyword.put(prepared.options, :deadline, deadline)

    case ConnectionSupervisor.start_link(options) do
      {:ok, root, descriptor} ->
        handoff(root, descriptor, initial, deadline)

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        failure(if(reason == :timeout, do: :timeout, else: :startup_failed))
    end
  end

  defp handoff(root, descriptor, initial, deadline) do
    try do
      result =
        with {:ok, provisional} <- Control.from_start_descriptor(descriptor),
             {:ok, control} <- ready_if_fresh(provisional, initial, deadline),
             :ok <- unexpired(deadline) do
          {:ok, root, control}
        end

      case result do
        {:ok, ^root, _control} ->
          result

        {:error, %Error{} = error} ->
          abort(root, descriptor.lifetime, initial.generation, deadline, error)
      end
    catch
      kind, reason ->
        ConnectionSupervisor.abort_start(root, descriptor.lifetime, deadline, initial.generation)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp ready_if_fresh(control, %{generation: 0, phase: :retired}, deadline),
    do: Control.await_ready(control, deadline)

  defp ready_if_fresh(control, _initial, _deadline), do: {:ok, control}

  defp abort(root, lifetime, generation, deadline, error) do
    {:error, cleanup} = ConnectionSupervisor.abort_start(root, lifetime, deadline, generation)

    {:error,
     %{
       error
       | phase: :connect,
         certainty: :unknown,
         details: Map.merge(error.details, cleanup.details)
     }}
  end

  defp deadline(timeout, entered_at) do
    unless is_integer(timeout) and timeout in 1..600_000 and is_integer(entered_at) and
             (entered_at + timeout) in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
           do:
             raise(
               ArgumentError,
               "control timeout must be 1..600000ms with a representable deadline"
             )

    Deadline.new(timeout, now: entered_at)
  end

  defp unexpired(deadline),
    do: if(Deadline.remaining(deadline) > 0, do: :ok, else: failure(:timeout))

  defp failure(kind),
    do:
      {:error,
       %Error{kind: kind, phase: :connect, certainty: :unknown, details: %{cleanup: :unknown}}}
end
