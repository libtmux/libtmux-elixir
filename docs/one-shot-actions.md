# Create, split, rename, send input and capture

Create sessions and windows on an existing server, split panes, rename, send
input and capture screen contents with the domain helpers.

- Pass a `LibTmux.Server` to choose one-shot execution.
- An action with a target reference first checks its captured server
  incarnation. That check leaves a check/use race; use
  [qualified control](managed-control.md) when a mutation must stay bound to a
  live connection.
- No action changes transport or retries with a positional target.

## Create

- `LibTmux.Server.new_session/3` creates a named detached session on an
  existing server. `LibTmux.Session.new_window/4` creates a named detached
  window in a referenced session.
- Both return the created ID with `ref: nil`; capture again to get a
  reference.
- Neither starts a missing daemon. Session creation reads no identity before
  dispatch.
- Both accept `timeout`, a literal `cwd` and the command forms below, except
  `:empty`.

## Run the example

This program renames a session and window, splits a pane, sends literal text
and a named key, then captures bounded screen bytes. The
[owned-server runner](owned-server.md) supplies its arguments and removes the
`cat` pane and server afterward:

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/one_shot_actions.exs
```

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

- Domain actions return `{:ok, result}` only when the command completes.
- Failed, skipped and unknown outcomes return
  `{:error, %LibTmux.Action.CompletionError{result: original_result}}` with the
  original evidence.
- Bang functions return the completed value or raise those errors. API and
  admitted execution errors keep their own types.
- An acknowledgement does not prove that input was consumed, the screen
  rendered or the program exited. The example prints the capture's byte
  count, not its text.
- [Return conventions](mental-model.md#return-conventions) compares this with
  `Control` and scoped callbacks.

| Task | Options and result |
| --- | --- |
| Create | `Server.new_session/3` or `Session.new_window/4`; named, detached creation on an existing server. Duplicate session names fail; duplicate window names are allowed. |
| Rename | `Session.rename/4` or `Window.rename/4`; 1..1024 UTF-8 bytes without Unicode control characters. tmux's name normalization remains version-dependent. |
| Split | `Pane.split/3`; vertical, half size and detached by default. Horizontal places panes side by side. Percent sizes use `-l N%`. `value` contains the pane `id` and `ref: nil`. |
| Literal input | `Pane.send_text/4`; 0..995 bytes, including NUL and invalid UTF-8. It never parses key names. More than 995 fails before any I/O. |
| Named input | `Pane.send_keys/4`; 1..128 supported names. Unsupported spellings fail before dispatch. See the API for modifiers. |
| Screen capture | `Pane.capture/3`; visible lines by default, 64 KiB stdout, negative history offsets allowed. An overflow is an error. This reads rendered screen state, not original program stdout. |

All actions default to one 5000ms budget.

- The library never splits a call into several mutations. Send larger input
  in batches of your own and handle partial delivery.
- A physical window can belong to several sessions. `session:` binds the
  action to membership in that session; it does not reserve a `WindowLink`
  index.
- A disappeared target fails. Old snapshots stay unchanged, and a returned
  ID does not refresh the graph.
- `details` keeps bounded transport evidence. A nonzero one-shot client exit
  is a failed outcome with its exit status; it does not prove that no side
  effect occurred.
- `LibTmux.Action` and the [advanced example](advanced-execution.md) cover
  lower-level results.

## Command forms

Use explicit intent when a pane command is assembled dynamically:

| `command` | Meaning |
| --- | --- |
| `:default` or omitted | Use the session default command/shell. |
| `:empty` | Split only: create a pane without a shell or program. |
| `{:shell, "program \| another_program"}` | Interpret nonempty text through the session's configured shell. |
| `{:argv, ["/path/to/program"]}` | Execute with exactly one argv entry. |
| `{:argv, ["program", "argument with spaces"]}` | Preserve each argv entry; use tmux's PATH lookup. |

- Argv follows `execvp`, including its shell fallback for executable text
  files.
- Empty argv, an empty program, empty shell text and NUL bytes fail before
  dispatch.
- Command byte ceilings include any adapter overhead. Other arguments may be
  empty or hold any non-NUL bytes.
- Adding or removing an argument never turns an argv list into shell text.

A singleton argv runs through the packaged native helper, which replaces
itself with the program without forking:

- tmux records the helper path in `pane_start_command` and reuses it for
  commandless respawn. Keep the installation in place while you need that.
- The program runs under tmux ownership, beyond the caller's lifetime.
- An acknowledged split can still be followed by a startup failure.
