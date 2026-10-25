# Create, split, rename, send input and capture

Create sessions and windows on an existing server, split panes, rename,
send input and capture screen contents with the domain helpers. Run the
packaged example with the [owned-server recipe](owned-server.md).

Pass a `LibTmux.Server` to choose one-shot execution. Actions taking a target
reference check its captured server incarnation before issuing the command.
That check leaves a check/use race; use [qualified control](managed-control.md)
when a supported mutation must remain bound to a live connection. No action changes transport or
retries with a positional target.

`LibTmux.Server.new_session/3` creates a named detached session on an existing
server. `LibTmux.Session.new_window/4` creates a named detached window in a
referenced session. Both use one-shot execution and return the created ID
with `ref: nil`; capture again to obtain a reference. Neither starts a missing
daemon. Session creation has no observed target and does not read an identity
before dispatch. These functions accept `timeout`, literal `cwd` and the
command forms below, except `:empty`.

This complete program renames a session and window, splits a pane, sends
literal text and a named key, then captures bounded screen bytes. It receives
the absolute executable, socket and exact session ID as arguments. It creates
a `cat` pane; the owned runner removes that pane and server after it returns.

<!-- example: examples/one_shot_actions.exs -->

```elixir
alias LibTmux.{Pane, Ref, Selection, Server, Session, Snapshot, Window}

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

Session.rename!(server, session_ref, "work")
Window.rename!(server, window_ref, "editor", session: session_ref)

%{id: created_id, ref: nil} =
  Pane.split!(server, pane_ref,
    axis: :horizontal,
    size: {:percent, 30},
    session: session_ref,
    command: {:argv, ["/bin/cat"]}
  )

{:ok, fresh} = Server.snapshot(server)
created = fresh |> Snapshot.panes() |> Selection.one!(id: created_id)
{:ok, created_ref} = Ref.from_observation(created)
Pane.send_text!(server, created_ref, "hello")
Pane.send_keys!(server, created_ref, ["Enter"])
screen = Pane.capture!(server, created_ref, max_bytes: 4096)

{:ok, %{name: "work"}} = Snapshot.fetch(fresh, :session, session.id)
{:ok, %{name: "editor"}} = Snapshot.fetch(fresh, :window, window.id)
false = Selection.member_id?(Snapshot.panes(snapshot), created_id)
IO.puts(JSON.encode!(%{created_pane: created_id, captured_bytes: byte_size(screen)}))
```

<!-- /example -->

Ordinary domain actions return `{:ok, result}` only when the command completes.
Failed, skipped and unknown outcomes return
`{:error, %LibTmux.Action.CompletionError{result: original_result}}` with the
full original evidence. Domain bang functions return completed values or
raise these errors. API and admitted execution errors remain unchanged.
See [return conventions](mental-model.md#return-conventions) for the
distinction from lower-level execution and scoped callbacks.
A command acknowledgement does not prove input consumption, screen
rendering or program exit. Consequently, the example reports the capture's
byte count without claiming that `hello` has already appeared.

| Task | Options and result |
| --- | --- |
| Create | `Server.new_session/3` or `Session.new_window/4`; named, detached creation on an existing server. Duplicate session names fail; duplicate window names are allowed. |
| Rename | `Session.rename/4` or `Window.rename/4`; 1..1024 UTF-8 bytes without Unicode control characters. tmux's name normalization remains version-dependent. |
| Split | `Pane.split/3`; vertical, half size and detached by default. Horizontal places panes side by side. Percent sizes use `-l N%`, including on tmux 3.4. `value` contains the pane `id` and `ref: nil`. |
| Literal input | `Pane.send_text/4`; 0..995 bytes, including NUL and invalid UTF-8. It never parses key names. |
| Named input | `Pane.send_keys/4`; 1..128 supported names. Unsupported spellings fail before dispatch. See the API for modifiers. |
| Screen capture | `Pane.capture/3`; visible lines by default, 64 KiB stdout, negative history offsets allowed. An overflow is an error. This reads rendered screen state, not original program stdout. |

All actions default to one 5000ms budget.

Migration: earlier alphas put unsuccessful domain outcomes inside `{:ok, result}`.
Match `{:error, %LibTmux.Action.CompletionError{result: result}}` to inspect them
now. Ordinary `with {:ok, result} <- action` composition requires command
completion and still retains successful metadata. Domain bangs and lower-level
`Control` and `Operation` return conventions have not changed.

The literal-input limit is now 995 bytes on both transports. Earlier alphas
advertised 1,020, but one-shot native admission rejected more than 246 bytes.
tmux 3.8's one-shot client limits this encoding to 995 input bytes (1,000
command arguments). One-shot inputs from 247 through 995 now work. Control
callers previously sending 996..1020 bytes now receive an `:invalid_command`
error at `[:text]`, as do all larger inputs on either transport, before I/O.
The library never splits a call into several mutations.
Applications sending larger inputs must choose their batching and handle
partial delivery explicitly.

A physical window can belong to several sessions. Optional `session:` binds
the action to membership in that exact session; it does not reserve a
particular `WindowLink` index. Disappeared targets fail. Old snapshots remain
unchanged, and a returned ID does not silently refresh the graph.

`details` preserves bounded transport evidence. A nonzero one-shot client
exit is a canonical failed outcome with observed exit status; it does not
prove that no side effect occurred. See `LibTmux.Action` and
[the advanced example](advanced-execution.md) for lower-level results.

## Command forms

Use explicit intent when a pane command is assembled dynamically:

| `command` | Meaning |
| --- | --- |
| `:default` or omitted | Use the session default command/shell. |
| `:empty` | Split only: create a pane without a shell or program. |
| `{:shell, "program \| another_program"}` | Interpret nonempty text through the session's configured shell. |
| `{:argv, ["/path/to/program"]}` | Execute with exactly one argv entry. |
| `{:argv, ["program", "argument with spaces"]}` | Preserve each argv entry; use tmux's PATH lookup. |

Argv follows `execvp`, including its shell fallback for executable text files.
Empty argv, an empty program, empty explicit shell text and NUL bytes are
rejected before dispatch. Existing command byte ceilings include any adapter
overhead. Other arguments may be empty or contain arbitrary non-NUL bytes.

For singleton argv, the packaged native helper replaces itself with the
program without forking. tmux records that helper path in `pane_start_command`
and retains it for commandless respawn. Keep the installation available while
that respawn behavior is needed; removing or relocating it can break respawn.
The program runs under tmux ownership, beyond the library caller's lifetime.
An acknowledged split can still be followed by program startup failure.

Adding or removing an argument in an argv list never changes it into shell text.
