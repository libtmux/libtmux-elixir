# Advanced: inspect both transports and own a retained operation

This example exposes retained operations and manual connection teardown. For
routine work, start with [capture and filter](first-task.md), then choose
[one-shot actions](one-shot-actions.md) or [managed control](managed-control.md).

Run it on a private server with the [owned-server runner](owned-server.md):

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/capture_and_read.exs
```

To run the whole packed-example check against an isolated tmux server, from a
source checkout:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

- It needs the toolchain from [Contributing](../.github/CONTRIBUTING.md#setup),
  plus Python 3 and tmux 3.3 or newer on `PATH`.
- Set `LIBTMUX_TMUX` to an absolute executable to check a particular tmux
  build.
- Hex must already be installed; the check downloads nothing.
- It builds and extracts a real package, compiles its core in a fresh
  directory and runs the packaged example outside the checkout.
- An owned fixture supplies a unique socket, an empty configuration and an
  existing session. It clears inherited `TMUX` and `TMUX_PANE`, verifies that
  its server, pane, clients and helper exited, and never uses the default
  server.

## The complete program

[Executable source](../examples/capture_and_read.exs) receives the absolute
tmux executable, socket and existing session ID from the fixture. All its
library calls use the public core.

<!-- example: examples/capture_and_read.exs -->

```elixir
alias LibTmux.{Codec, Command, Control, Format, Operation, Ref, Selection, Server, Snapshot}
alias LibTmux.Control.Request

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    cwd: "/",
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

{:ok, snapshot} = Server.snapshot(server)
session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Snapshot.related(snapshot, :session, session.id, :active_window)

pane =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(window_id: window.id)
  |> Selection.filter(& &1.active)
  |> Selection.one!()

{:ok, target} = Ref.new(:pane, pane.id, snapshot.server_instance)
command = Command.new("display-message", ["-p", "-t", pane.id, Format.field("pane_id")])
{:ok, %{stdout: stdout, cleanup: :retired}} = Server.run(server, command)
{:ok, one_shot_id} = Codec.decode_field(stdout, :string, encoding: :escaped_v1)
true = one_shot_id == pane.id

{:ok, root, control} =
  Control.start_link(
    server: server,
    session: {:existing, session.id},
    lane: :host_qualified,
    timeout: 800
  )

root_monitor = Process.monitor(root)

control_id =
  try do
    {:ok, operation} = Control.submit(control, Request.field("pane_id", target), timeout: 800)

    {:ok,
     %{
       outcome: :completed,
       certainty: :acknowledged,
       evidence: :command_reply,
       lines: [line]
     }} = Operation.await(operation, timeout: 800)

    {:ok, %{phase: :ready}} = Control.status(control)
    {:ok, %{result: %{outcome: :completed}}} = Operation.status(operation)

    {:ok, id} = Codec.decode_field(line <> "\n", :string, encoding: :escaped_v1)
    true = id == pane.id
    :ok = Control.close(control, timeout: 800)
    {:ok, %{phase: :retired, terminal: %{reason: :closure_requested}}} = Control.status(control)
    {:ok, %{outcome: :completed}} = Operation.result(operation)
    :ok = Operation.forget(operation, timeout: 800)
    id
  after
    try do
      :ok = Control.close(control, timeout: 800)
    after
      :ok = Supervisor.stop(root, :normal, 800)

      receive do
        {:DOWN, ^root_monitor, :process, ^root, :normal} -> :ok
      after
        800 -> raise "connection supervisor did not exit"
      end
    end
  end

IO.puts(
  JSON.encode!(%{
    "session" => session.id,
    "window" => window.id,
    "pane" => pane.id,
    "oneShot" => one_shot_id,
    "control" => control_id,
    "connectionRetired" => true
  })
)
```

<!-- /example -->

- The result holds the observed session, window and pane IDs. Both replies
  must identify the selected pane.
- `connectionRetired` is true only after the connection closes and its
  supervisor exits.
- The harness checks that the borrowed server and pane survived, then tears
  down its own fixture.
- After closure, `LibTmux.Control.status/1` keeps the observed close reason and
  bounded captured stderr until epoch replacement or context loss. Inspect
  that report before reconnecting or shutting its owner down.
- The example checks requested closure and the unchanged completed operation.
  An unexpected close can have a different reason or no evidence.
- Captured stderr can contain application data.

## What each step establishes

- `LibTmux.Server.snapshot/2` observes a capture interval. `LibTmux.Selection`
  then runs `where`, a native predicate and checked cardinality locally, with
  no further tmux command, and relationships resolve against the same graph.
- The one-shot read uses an exact pane ID and the escaped field codec. Its
  check/use race remains: a captured pane is not reserved.
- The control request also carries a `LibTmux.Ref` bound to the observed server
  incarnation.
- Control startup attaches a client and can change session state and
  attachment counts. The fixture's empty, controlled configuration is why this
  example can declare `lane: :host_qualified`. On another server, qualify its
  effective hooks, aliases and stream writers first.
- `LibTmux.Control.submit/3` returns an admitted operation. The example checks
  that `LibTmux.Operation.await/2` reports `:completed` and `:acknowledged`. A
  reply acknowledges this tmux command; it does not prove that a program
  started by another command has exited.

## Failure behavior and cleanup

- The program uses assertions, so an unexpected result fails the example.
- Capture and transport errors return `{:error, %LibTmux.Error{}}`, with
  `kind`, `phase` and `certainty` describing the failure.
- A control field read whose target disappeared returns an acknowledged
  `:failed` operation. A present empty field stays `:completed`.
- Raw one-shot commands keep tmux's native semantics, so the example also
  checks the returned pane ID. Neither path retries with a positional target.
- `LibTmux.Selection.one!/2` raises `:no_match` or `:multiple_matches` instead
  of selecting arbitrarily.
- An await timeout ends only that waiter. Failed, skipped and unknown outcomes
  are values, including from bang functions. Inspect the retained operation
  instead of replaying an uncertain command. This example accepts only an
  acknowledged completed read.
- The `after` block closes the connection and stops its enclosing supervisor.
  The fixture harness runs owned teardown even when the example fails.

See [the mental model](mental-model.md) and [ownership](ownership.md) for the
different lifetimes and remaining limits.
