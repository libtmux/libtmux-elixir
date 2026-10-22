# Capture a pane and read it through both transports

From a source checkout, run one complete example against an isolated tmux
server:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

Use the development toolchain and Linux prerequisites in
[Contributing](../.github/CONTRIBUTING.md#setup), plus Python 3 and tmux 3.3 or
newer on `PATH`. Set `LIBTMUX_TMUX` to an absolute executable when checking a
particular tmux build. Hex must already be installed; the check downloads
nothing.

The check builds and extracts a real package, compiles its core in a fresh
directory, and executes the packaged example outside the checkout. An owned
fixture supplies a unique socket, empty configuration and existing session.
It clears inherited `TMUX` and `TMUX_PANE` and verifies its server, pane,
clients and helper exit afterward. It never uses the default server.

## The complete program

[Executable source](../examples/capture_and_read.exs) receives the absolute
tmux executable, socket and existing session ID from that fixture. All its
library calls use the public core. The embedded program is checked against
that source file.

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

    {:ok, id} = Codec.decode_field(line <> "\n", :string, encoding: :escaped_v1)
    true = id == pane.id
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

The result contains the observed session, window and pane IDs. Both replies
must identify the selected pane, and `connectionRetired` is true only after
connection close and supervisor exit succeed. The harness checks that the
borrowed server and pane survived the program, then tears down its own fixture.

## What each step establishes

`LibTmux.Server.snapshot/2` observes a capture interval. `LibTmux.Selection`
then runs `where`, a native predicate and checked cardinality locally, without
another tmux command. Relationships resolve against the same graph. Keep
using that snapshot when several decisions need the same captured values.

The one-shot read uses an exact pane ID and the escaped field codec. Its
check/use race remains: a captured pane is not reserved. The control request
also carries a `LibTmux.Ref` bound to the observed server incarnation.

Control startup explicitly attaches a client and can change session state
and attachment counts. The fixture's empty, controlled configuration is why
this example can declare `lane: :host_qualified`. A caller using another
server must qualify its effective hooks, aliases and stream writers before
using that lane; the option does not perform that qualification.

`LibTmux.Control.submit/3` returns an admitted operation. The example checks
the result of `LibTmux.Operation.await/2` for both `:completed` and
`:acknowledged`. A reply acknowledges this tmux command; it does not prove
that an arbitrary program started by another command has exited.

## Failure behavior and cleanup

The program uses assertions so unexpected results make the example fail.
Capture and transport errors return `{:error, %LibTmux.Error{}}`, with `kind`,
`phase` and `certainty` describing the failure. A control field read whose
target disappeared returns an acknowledged `:failed` operation; a present
empty field remains `:completed`. Raw one-shot commands retain tmux's native
semantics, so the example also checks the returned pane ID. Neither path
retries with a positional target.
`LibTmux.Selection.one!/2` raises `:no_match` or `:multiple_matches` rather
than selecting arbitrarily.

An await API timeout ends only that waiter. Canonical failed, skipped and
unknown operation outcomes are values, including from bang methods. Inspect
the retained operation instead of replaying an uncertain command. This
example deliberately accepts only an acknowledged completed read.

The `after` block closes the connection and stops its enclosing supervisor.
The separate fixture harness runs owned teardown even when the example
fails. See [the mental model](mental-model.md) and
[ownership](ownership.md) for the different lifetimes and remaining runtime
qualification limits.
