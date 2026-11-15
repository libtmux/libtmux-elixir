# Capture and filter a server

Capture once, then query the immutable result with no more tmux commands.
Install the published package as shown in the
[README](../README.md#installation), then save this program as
`capture_and_filter.exs`. It starts a private server with
[`Server.with_owned/2`](owned-server.md), so it runs as it is:

<!-- example: examples/capture_and_filter.exs -->

```elixir
alias LibTmux.{Selection, Server, Snapshot}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

  {:ok, snapshot} = Server.snapshot(server)

  active_ids =
    snapshot
    |> Snapshot.panes()
    |> Selection.where(active: true)
    |> Enum.map(& &1.id)

  IO.puts(JSON.encode!(%{active_panes: active_ids}))
end)
```

<!-- /example -->

Run it with tmux 3.3 or newer on `PATH`:

```console
$ mix run capture_and_filter.exs
```

It prints the IDs of the active panes, in numeric order, as JSON.

- To capture a server that already runs, build the descriptor with
  `Server.new/1` in place of `Server.with_owned/2`, passing `socket:` or
  `socket_name:`.
- With neither, `Server.new/1` reads `LIBTMUX_SOCKET_PATH`, then
  `LIBTMUX_SOCKET` (a socket name). With neither set, it passes tmux no socket,
  and tmux uses its default socket.
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

Next: [filter and select](filtering.md), [one-shot actions](one-shot-actions.md)
or [managed control](managed-control.md).
