# Capture and filter an existing server

Capture once, then query the immutable result without more tmux commands.
This example works with the published `0.0.1-alpha.3` package. Install it in
an Elixir project as shown in the [README](../README.md#installation).

Save this program as `capture_and_filter.exs` in your application:

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

Set `LIBTMUX_TMUX` to the absolute tmux executable and `LIBTMUX_SOCKET` to
the absolute socket of the existing server you intend to observe. Run:

```console
$ mix run capture_and_filter.exs "$LIBTMUX_TMUX" "$LIBTMUX_SOCKET"
```

The JSON result lists active physical pane IDs in numeric order. A pane is
active within its physical window; this is not a choice of one session's
active window. Linked windows do not duplicate their panes.

`Server.new/1` builds a descriptor without I/O. `Server.snapshot/2` runs
bounded one-shot reads without attaching a control client or creating a
missing server. `Selection.where/2` and `Enum.map/2` use the captured graph.
Capturing covers an interval, not an atomic tmux transaction. Capture again
explicitly when fresh state is needed.

The pattern match makes a capture error visible; production callers can
handle `{:error, %LibTmux.Error{}}`. The default capture budgets are 5000ms,
512 commands, 1024 contextual rows, 64 KiB per response and 8 MiB total.
A limit failure returns an error rather than a partial graph.

For an isolated demonstration, use the [owned-server recipe](owned-server.md).
Next: [filter and select](filtering.md), [one-shot actions](one-shot-actions.md),
or [managed control](managed-control.md).
