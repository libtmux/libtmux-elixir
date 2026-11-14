# Keep a control connection in an application

- Use an application owner when several callers need the current connection
  handle. The owner stores the handle and serializes explicit replacement.
- Commands still run in the requesting process, so managed execution and
  recovery belong to that caller.
- For a short task, prefer
  [`Control.with_connection/2`](LibTmux.Control.html#with_connection/2).

The program is `examples/supervised_control.exs`. Run it on a private server
with the [owned-server runner](owned-server.md). The displayed parts omit
argument setup, application shutdown and the fixture's process-exit checks:

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/supervised_control.exs
```

## Store the handle

`ApplicationConnection` is application code, not a library module. Its
separate connection supervisor must already be running when the owner
initializes. Calling the supervisor that is still starting the owner would
deadlock.

<!-- example: examples/supervised_control.exs#owner -->

```elixir
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

```

<!-- /example -->

- `replace/1` asks the supervisor for fresh startup information from its
  stored child specification. It never builds a new lifetime to bypass
  uncertain cleanup.
- `reconnect/1` leaves an unknown connection unavailable and returns the
  original error.
- Do not retry an uncertain mutation after replacement.

## Start the application children

Here `application` is a started application supervisor, `server` is the
`LibTmux.Server` descriptor and `session_id` names an existing session. The
complete file supplies them. The host must qualify its
[control lane](managed-control.md) before you set `lane: :host_qualified`.

<!-- example: examples/supervised_control.exs#application -->

```elixir
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

```

<!-- /example -->

- `execute/2` gets a handle with `GenServer.call/2`, then runs
  `Control.execute/3` outside the owner.
- Its result follows the lower-level
  [return convention](mental-model.md#return-conventions): inspect the
  canonical outcome.
- Handle access alone cannot keep the connection alive.

## Replace deliberately, then reconnect

- Quiesce application callers before replacing a connection. Replacement can
  interrupt sibling work, and this owner does not track or drain in-flight
  calls.
- For planned replacement, close first.
- After an automatic root restart, an old handle reports context loss and the
  replacement stays inert.

<!-- example: examples/supervised_control.exs#recovery -->

```elixir
alias LibTmux.Control
alias LibTmux.Control.Request

{:ok, original} = ApplicationConnection.connection(owner)
:ok = Control.close(original, timeout: 900)
{:ok, inert} = ApplicationConnection.replace(owner)
{:ok, %{phase: :retired}} = Control.status(inert)
{:ok, ready} = ApplicationConnection.reconnect(owner)

{:ok, %{outcome: :completed}} = ApplicationConnection.execute(owner, Request.field("pid"))
:ok = Control.close(ready, timeout: 900)
```

<!-- /example -->

After an automatic root restart, call `replace/1` directly. `close/2` cannot
repair the lost handle.

- If the old connection retired, reconnect can attach.
- If cleanup is unknown, `reconnect/1` returns
  `{:error, %LibTmux.Error{kind: :cleanup_unknown}}` and the owner keeps the
  unavailable handle. Stop application work and keep that evidence; rebuilding
  the child specification is not recovery.
- The tests exercise both branches with actual root death, and check that an
  earlier completed mutation is not replayed.

The owner is temporary. If it exits, the application still owns the connection
subtree; stop the application to shut it down.

- This recipe covers one connection while the owner and its separate
  supervisor survive.
- Owner, connection-supervisor and whole-application recovery need your own
  policy.
- For command uncertainty inside a live owner, use the
  [execution recovery example](recovery.md).
