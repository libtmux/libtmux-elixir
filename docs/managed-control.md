# Run repeated work with managed control

`Control.with_connection/2` owns connection and supervisor teardown around a
callback. Run the example on a private server with the
[owned-server runner](owned-server.md):

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/managed_control.exs
```

## Before you start

- Control attaches to an existing session, so it changes tmux attachment
  counts.
- You must qualify the host for the connection's whole lifetime: effective
  hooks, aliases, input-mode bindings and other writers.
- `lane: :host_qualified` declares that you did. It does not inspect or repair
  configuration.
- The owned runner qualifies it: a private server, an empty config and no
  other clients.

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

- Domain bang actions return completed values or raise with the original
  failure evidence. `Control.execute!` keeps canonical outcomes for you to
  inspect.
- The split returns a bound reference, used at once for input and field
  reads. The captured snapshot stays unchanged.
- The program runs every action and 128 field reads at the default capacity
  of 32. `Control.execute/3` owns each command through wire retirement and
  record reclamation, so repeated calls need no `forget`, retention sleep or
  larger capacity.
- `connection_retired: true` prints only after the scope confirms native
  retirement and supervisor exit.
- The runner owns the server and panes. It checks that they survived before
  its own teardown.

## Choose the transport explicitly

| Operation | `Server` one-shot | Qualified `Control` |
| --- | --- | --- |
| Split, rename, literal text, named keys | Supported, with an incarnation check/use race | Managed execution bound to the connection |
| Created pane reference | `value.ref: nil`; ID in `value.id` | Bound `value.ref` on a completed split |
| Screen capture | Bounded bytes | Returns `unsupported_transport`; no fallback |
| Encoded field read | `Command` + `Format` + `Server.run` | `Request.field` + `Control.execute` |
| Arbitrary trusted command | `Server.run` | Outside the qualified request lane |

## Inspect failures without replaying

- For a connection your application owns, the
  [supervision recipe](supervised-control.md) shows handle access and explicit
  replacement after a restart.
- The [recovery example](recovery.md) handles admission errors, unsuccessful
  outcomes, lost operation context and cleanup failure in one application.
- `execute/3` returns `{:ok, outcome}` only after wire retirement and record
  reclamation. A failed command is still a canonical outcome.
- `execute!/3` raises API and context errors, and can return `:failed`,
  `:skipped` or `:unknown`. Check the outcome you need, as the program does.
- Before admission, errors are `LibTmux.Error` with no-write certainty. After
  admission, `LibTmux.Control.ExecutionError` carries the `operation` and its
  `context`, `:retained` or `:lost`.
- While context exists, inspect `Operation.status/1` or `Operation.result/1`.
- A timeout does not authorize replay.
- A new `await/2` needs a waiter slot. An expired collector frees its slot
  when the owner processes closure, so an immediate re-wait can report
  overload.
- The original managed caller owns recovery. Its death permits record
  reclamation after wire retirement, even if it passed the handle on. Use
  `submit/3` when another process needs independently retained results.

## Retained operations and cleanup

- `Control.submit/3` plus `Operation.await/2` retains a handle. Await can
  return before wire retirement and does not free admission capacity.
- `forget/2` refuses active wire records. Unforgotten records become
  reclaimable at their operation deadline plus `retention_ms` (default
  60000ms), once the connection owner runs and the wire retires. Accepted
  waiter results are kept before the slot is reused.
- Retained mode can fill its capacity even when every command completed. The
  [advanced example](advanced-execution.md) shows explicit ownership.
- `Operation.await!/2` also returns canonical failures as values.
  **`Operation.stop/1` can close the whole epoch, including siblings.**
- The scope callback runs in the caller, with no library duration timer.
  Startup and cleanup have separate budgets; cleanup defaults to 950ms.
- A successful scope returns `{:ok, callback_value}`. With proven cleanup,
  callback exceptions, throws and exits are re-raised.
- A cleanup failure returns `{:error, %LibTmux.Control.ScopeFailure{}}`, which
  keeps the primary callback value or exception beside the cleanup evidence.
  Do not discard either field. Unknown cleanup is not successful retirement.
- Startup uses an initialization budget, not a strict wall-clock return
  guarantee; see [ownership](ownership.md).
