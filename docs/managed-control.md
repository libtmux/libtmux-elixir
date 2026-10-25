# Run repeated work with managed control

Managed execution and scoped connections are available in `0.0.1-alpha.3`.
Use the [owned-server recipe](owned-server.md) to run the example from a
packed copy of the library.

`Control.with_connection/2` owns connection and supervisor teardown around a
callback. `Control.execute/3` owns a command through wire retirement and
record reclamation. Successful repeated calls need no manual `forget`,
retention sleep or larger capacity.

Control attaches to an existing session and affects tmux attachment counts.
The host must qualify effective hooks, aliases, input-mode bindings and other
writers for the whole connection lifetime. `lane: :host_qualified` declares
that work; it does not inspect or repair configuration. The owned runner
below uses a private empty-config server with no uncontrolled peers.

<!-- example: examples/managed_control.exs -->

```elixir
alias LibTmux.{Control, Pane, Ref, Selection, Server, Session, Snapshot, Window}
alias LibTmux.Control.Request

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

{:ok, snapshot} = Server.snapshot(server)
session = snapshot |> Snapshot.sessions() |> Selection.one!(id: session_id)
window = Session.active_window(snapshot, session)
pane = snapshot |> Snapshot.panes() |> Selection.one!(window_id: window.id, active: true)
{:ok, session_ref} = Ref.from_observation(session)
{:ok, window_ref} = Ref.from_observation(window)
{:ok, pane_ref} = Ref.from_observation(pane)

{:ok, created_id} =
  Control.with_connection(
    [server: server, session: {:existing, session.id}, lane: :host_qualified],
    fn control ->
      :ok = Session.rename!(control, session_ref, "work")
      :ok = Window.rename!(control, window_ref, "editor")

      %{id: id, ref: created} =
        Pane.split!(control, pane_ref, command: {:argv, ["/bin/cat"]})

      false = snapshot |> Snapshot.panes() |> Selection.member_id?(id)
      :ok = Pane.send_text!(control, created, "hello")
      :ok = Pane.send_keys!(control, created, ["Enter"])

      for _ <- 1..128 do
        %{outcome: :completed, certainty: :acknowledged, lines: ["v1:" <> ^id]} =
          Control.execute!(control, Request.field("pane_id", created))
      end

      id
    end
  )

IO.puts(JSON.encode!(%{created_pane: created_id, repeated_reads: 128, connection_retired: true}))
```

<!-- /example -->

Domain bang actions return completed values or raise with the original failure
evidence. `Control.execute!` retains canonical outcomes for explicit inspection.
The split returns a bound reference used immediately for input and field
reads. The captured snapshot remains unchanged. This runs all actions and
128 field reads at the default capacity of 32.
`connection_retired: true` is printed only after the scope confirms native
retirement and supervisor exit. The server and panes belong to the runner,
which checks their survival before its separate teardown.

## Choose the transport explicitly

| Operation | `Server` one-shot | Qualified `Control` |
| --- | --- | --- |
| Split, rename, literal text, named keys | Supported, with an incarnation check/use race | Managed execution bound to the connection |
| Created pane reference | `value.ref: nil`; ID in `value.id` | Bound `value.ref` on a completed split |
| Screen capture | Bounded bytes | Returns `unsupported_transport`; no fallback |
| Encoded field read | `Command` + `Format` + `Server.run` | `Request.field` + `Control.execute` |
| Arbitrary trusted command | `Server.run` | Outside the qualified request lane |

## Inspect failures without replaying

For a connection owned by an application, the
[supervision recipe](supervised-control.md) shows handle access and explicit
replacement after a restart.

The [recovery example](recovery.md) handles admission errors, unsuccessful
outcomes, lost operation context and cleanup failure in one application.

`execute/3` returns `{:ok, outcome}` only after wire retirement and record
reclamation. A failed command is still a canonical outcome. `execute!/3`
raises API/context errors; it can return `:failed`, `:skipped` or `:unknown`.
Check the outcome you require, as the program above does.

Before admission, errors are `LibTmux.Error` with no-write certainty. After
admission, `LibTmux.Control.ExecutionError` includes the exact `operation` and
`context` (`:retained` or `:lost`). Inspect `Operation.status/1` or
`Operation.result/1` while context exists. A timeout does not authorize replay.
A new `await/2` needs a waiter slot; an expired collector releases its slot
when the owner processes closure, so immediate re-waiting can report overload.

The original managed caller owns error recovery. Its death permits record
reclamation after wire retirement, even if it passed the handle elsewhere.
Use `submit/3` when another process needs independently retained results.

## Retained operations and cleanup

`Control.submit/3` plus `Operation.await/2` retains a handle. Await can return
before wire retirement and does not free admission capacity. `forget/2`
refuses active wire records. Unforgotten records become eligible for reclamation
at their operation deadline plus `retention_ms` (default 60000ms). Reclamation
requires the connection owner to run and the wire to retire; accepted waiter
results are preserved before the slot is reused. Retained mode can fill its
capacity even when all commands completed. The [advanced example](advanced-execution.md)
shows explicit ownership. `Operation.await!/2` also keeps canonical failures
as values. **`Operation.stop/1` can close the whole epoch, including siblings.**

The scope callback runs in the caller with no library duration timer. Startup
and cleanup have separate budgets; cleanup defaults to 950ms. A successful
scope returns `{:ok, callback_value}`. With proven cleanup, callback exceptions,
throws and exits are re-raised. Cleanup failure returns
`{:error, %LibTmux.Control.ScopeFailure{}}`, preserving the primary callback
value or exception alongside cleanup evidence. Do not discard either field.
Unknown cleanup is not successful retirement. Startup uses an initialization
budget, not a strict wall-clock return guarantee; see [ownership](ownership.md).
