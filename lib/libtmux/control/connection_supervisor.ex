defmodule LibTmux.Control.ConnectionSupervisor do
  @moduledoc false
  use Supervisor
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{EpochHost, Lifetime, Manager, SupervisorStart}
  alias LibTmux.Transport.Native.Driver
  alias LibTmux.Transport.Reply

  def child_spec(options) do
    options =
      Keyword.validate!(options, [
        :deadline,
        :payload,
        :lifetime,
        driver: {Driver, []},
        capacity: 32,
        metadata_capacity: 32,
        waiter_capacity: 32,
        retention_ms: 60_000
      ])

    %Deadline{} = Keyword.fetch!(options, :deadline)
    payload = Keyword.fetch!(options, :payload)

    unless is_binary(payload) and byte_size(payload) <= 32_768 and
             is_integer(options[:capacity]) and options[:capacity] in 1..256 and
             is_integer(options[:metadata_capacity]) and options[:metadata_capacity] in 1..256 and
             is_integer(options[:waiter_capacity]) and options[:waiter_capacity] in 1..256 and
             is_integer(options[:retention_ms]) and options[:retention_ms] in 1..600_000,
           do: raise(ArgumentError, "invalid bounded connection options")

    options =
      options
      |> Keyword.put(:payload, :binary.copy(payload))
      |> Keyword.put_new_lazy(:lifetime, &Lifetime.new/0)

    %Lifetime{} = options[:lifetime]

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :permanent,
      type: :supervisor,
      shutdown: 950
    }
  end

  def start_link(options) do
    %Lifetime{} = lifetime = Keyword.fetch!(options, :lifetime)
    %Deadline{} = deadline = Keyword.fetch!(options, :deadline)
    generation = Lifetime.status(lifetime).generation
    reply = :erlang.alias()
    token = make_ref()

    try do
      case SupervisorStart.start_link(__MODULE__, {options, reply, token}, deadline) do
        {:ok, root} ->
          receive do
            {^token, %{owner: ^root, lifetime: ^lifetime, view: view} = descriptor}
            when is_reference(view) ->
              if :ets.info(view, :owner) == root and Deadline.remaining(deadline) > 0,
                do: {:ok, root, descriptor},
                else: unpublished(root, lifetime, deadline, generation)

            {^token, _invalid} ->
              unpublished(root, lifetime, deadline, generation)
          after
            0 -> unpublished(root, lifetime, deadline, generation)
          end

        error ->
          abandon(lifetime, generation)
          error
      end
    catch
      kind, reason ->
        abandon(lifetime, generation)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Reply.close(reply, token)
    end
  end

  @impl true
  def init({options, reply, token}) do
    view = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    :ets.insert(view, {:context, %{owner: self(), lifetime: options[:lifetime]}})
    send(reply, {token, %{owner: self(), view: view, lifetime: options[:lifetime]}})

    Supervisor.init(
      [
        Supervisor.child_spec({EpochHost, view}, shutdown: 950),
        %{
          id: Manager,
          start: {__MODULE__, :start_manager, [view, options]},
          restart: :permanent,
          shutdown: 950
        }
      ],
      strategy: :one_for_all
    )
  end

  def start_manager(view, options) do
    true = :ets.info(view, :owner) == self()
    [{:host, host}] = :ets.lookup(view, :host)
    Manager.start_link(options ++ [host: host, view: view])
  end

  defp unpublished(root, lifetime, deadline, generation) do
    abandon(lifetime, generation)
    monitor = Process.monitor(root)
    Process.unlink(root)
    Process.exit(root, :kill)

    receive do
      {:EXIT, ^root, _reason} -> :ok
    after
      0 -> :ok
    end

    root_exited =
      receive do
        {:DOWN, ^monitor, :process, ^root, _reason} -> true
      after
        Deadline.remaining(deadline) -> false
      end

    Process.demonitor(monitor, [:flush])

    {:error,
     %Error{
       kind: :startup_handoff_lost,
       phase: :connect,
       certainty: :unknown,
       details: %{root: root, root_exited: root_exited, cleanup: :unknown}
     }}
  end

  defp abandon(lifetime, 0), do: Lifetime.abandon_initial(lifetime)
  defp abandon(lifetime, generation), do: Lifetime.abandon(lifetime, generation)
end
