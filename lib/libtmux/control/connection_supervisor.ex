defmodule LibTmux.Control.ConnectionSupervisor do
  @moduledoc false
  use Supervisor
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{EpochHost, Lifetime, Manager}
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
        retention_ms: 60_000
      ])

    %Deadline{} = Keyword.fetch!(options, :deadline)
    payload = Keyword.fetch!(options, :payload)

    unless is_binary(payload) and byte_size(payload) <= 32_768 and
             is_integer(options[:capacity]) and options[:capacity] in 1..256 and
             is_integer(options[:metadata_capacity]) and options[:metadata_capacity] in 1..256 and
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
    reply = :erlang.alias()
    token = make_ref()

    try do
      case Supervisor.start_link(__MODULE__, {options, reply, token}) do
        {:ok, root} ->
          receive do
            {^token, %{owner: ^root, lifetime: ^lifetime, view: view} = descriptor}
            when is_reference(view) ->
              if :ets.info(view, :owner) == root,
                do: {:ok, root, descriptor},
                else: unpublished(root, lifetime)

            {^token, _invalid} ->
              unpublished(root, lifetime)
          after
            0 -> unpublished(root, lifetime)
          end

        error ->
          error
      end
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

  defp unpublished(root, lifetime) do
    %{generation: generation} = Lifetime.status(lifetime)
    if generation > 0, do: Lifetime.abandon(lifetime, generation)
    monitor = Process.monitor(root)
    Process.unlink(root)
    Process.exit(root, :kill)

    root_exited =
      receive do
        {:DOWN, ^monitor, :process, ^root, _reason} -> true
      after
        500 -> false
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
end
