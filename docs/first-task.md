# Capture and filter an existing server

Capture once, then query the immutable result with no more tmux commands.
Install the published package as shown in the
[README](../README.md#installation), then save this program as
`capture_and_filter.exs`:

<!-- example: examples/capture_and_filter.exs -->

```elixir
alias LibTmux.{Selection, Server, Snapshot}

[executable, socket | _] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

{:ok, snapshot} = Server.snapshot(server)

active_ids =
  snapshot
  |> Snapshot.panes()
  |> Selection.where(active: true)
  |> Enum.map(& &1.id)

IO.puts(JSON.encode!(%{active_panes: active_ids}))
```

<!-- /example -->

Set `LIBTMUX_TMUX` to the absolute path of tmux and `LIBTMUX_SOCKET_PATH` to
the absolute socket path of the server you want to observe. Run:

```console
$ mix run capture_and_filter.exs "$LIBTMUX_TMUX" "$LIBTMUX_SOCKET_PATH"
```

It prints the IDs of the active panes, in numeric order, as JSON.

- The program passes `socket:` itself, so it never reads those variables.
- With neither `socket:` nor `socket_name:`, `LibTmux.Server.new/1` reads
  `LIBTMUX_SOCKET_PATH`, then `LIBTMUX_SOCKET` (a socket name). With neither
  set, it passes tmux no socket, and tmux uses its default socket.
- A pane is active within its physical window. This does not choose one
  session's active window. Linked windows do not duplicate their panes.
- `Server.new/1` builds a descriptor with no I/O. `Server.snapshot/2` runs
  bounded one-shot reads, without attaching a control client or creating a
  missing server.
- `Selection.where/2` and `Enum.map/2` use the captured graph.
- Capture covers an interval, not an atomic tmux transaction. Capture again
  for fresh state.
- The `{:ok, snapshot}` match makes a capture error visible. Production code
  can handle `{:error, %LibTmux.Error{}}`.
- Default capture budgets: 5000ms, 512 commands, 1024 contextual topology
  rows, 64 KiB per response and 8 MiB in total. A limit failure returns an
  error, not a partial graph.

For an isolated demonstration, use the [owned-server runner](owned-server.md).
Next: [filter and select](filtering.md), [one-shot actions](one-shot-actions.md)
or [managed control](managed-control.md).
