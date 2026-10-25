# docs:begin owner
defmodule ApplicationConnection do
  use GenServer, restart: :temporary
  alias LibTmux.{Control, Error}

  def start_link({supervisor, options}),
    do: GenServer.start_link(__MODULE__, {supervisor, options})

  def connection(owner), do: GenServer.call(owner, :connection)
  def replace(owner), do: GenServer.call(owner, :replace)
  def reconnect(owner), do: GenServer.call(owner, :reconnect)

  def execute(owner, request) do
    with {:ok, control} <- connection(owner),
         do: Control.execute(control, request, timeout: 900)
  end

  @impl true
  def init({supervisor, options}) do
    case Supervisor.start_child(supervisor, Control.child_spec(options)) do
      {:ok, _root, control} -> {:ok, %{supervisor: supervisor, control: control}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:connection, _from, %{control: nil} = state),
    do: {:reply, {:error, :connection_unavailable}, state}

  def handle_call(:connection, _from, state), do: {:reply, {:ok, state.control}, state}

  def handle_call(:replace, _from, state) do
    with :ok <- Supervisor.terminate_child(state.supervisor, Control),
         {:ok, _root, control} <- Supervisor.restart_child(state.supervisor, Control) do
      {:reply, {:ok, control}, %{state | control: control}}
    else
      {:error, _reason} = error -> {:reply, error, %{state | control: nil}}
    end
  end

  def handle_call(:reconnect, _from, %{control: nil} = state),
    do: {:reply, {:error, :connection_unavailable}, state}

  def handle_call(:reconnect, _from, state) do
    case Control.reconnect(state.control, timeout: 900) do
      {:ok, ready} ->
        {:reply, {:ok, ready}, %{state | control: ready}}

      {:error, %Error{kind: :cleanup_unknown} = error} ->
        # A fresh child spec would bypass the existing cleanup state.
        {:reply, {:error, error}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end
end

# docs:end owner

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)
server = LibTmux.Server.new(executable: executable, socket: socket)
{:ok, application} = Supervisor.start_link([], strategy: :one_for_one)
monitor = Process.monitor(application)

try do
  # docs:begin application
  alias LibTmux.Control.Request

  {:ok, connections} =
    Supervisor.start_child(application, %{
      id: :connections,
      start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
      type: :supervisor
    })

  options = [
    server: server,
    session: {:existing, session_id},
    lane: :host_qualified,
    timeout: 900
  ]

  {:ok, owner} =
    Supervisor.start_child(application, {ApplicationConnection, {connections, options}})

  {:ok, %{outcome: :completed}} =
    ApplicationConnection.execute(owner, Request.set_user_option("@supervised_example", "once"))

  # docs:end application

  # docs:begin recovery
  alias LibTmux.Control
  alias LibTmux.Control.Request

  {:ok, original} = ApplicationConnection.connection(owner)
  :ok = Control.close(original, timeout: 900)
  {:ok, inert} = ApplicationConnection.replace(owner)
  {:ok, %{phase: :retired}} = Control.status(inert)
  {:ok, ready} = ApplicationConnection.reconnect(owner)

  {:ok, %{outcome: :completed}} = ApplicationConnection.execute(owner, Request.field("pid"))
  :ok = Control.close(ready, timeout: 900)
  # docs:end recovery

  IO.puts(JSON.encode!(%{supervised_control: "completed", explicit_reconnect: true}))
after
  :ok = Supervisor.stop(application, :normal, 950)

  receive do
    {:DOWN, ^monitor, :process, ^application, :normal} -> :ok
  after
    900 -> raise "application supervisor did not exit"
  end
end
