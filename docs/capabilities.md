# Check the connected daemon's tmux features

Call `Server.capabilities/2` for a server descriptor or `Control.capabilities/2`
for an established control connection. The release comes from the daemon;
a different client executable does not change the decision.

With tmux on `PATH`, run this program from the checkout:

```console
$ mix run examples/capabilities.exs
```

<!-- example: examples/capabilities.exs -->

```elixir
alias LibTmux.{Capabilities, Command, Control, Server}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, report} = Server.capabilities(server)

  event_wait =
    case Capabilities.require(report, "event-wait") do
      {:ok, %{scope: :tmux_primitive}} ->
        {:ok, %{stdout: ""}} =
          Server.run(server, Command.new("wait-for", ["-E", "-l", "pane-created"]))

        "available"

      {:error, %{kind: :unsupported_feature, certainty: :no_write}} ->
        "refused"
    end

  {:ok, %{value: %{id: id}}} =
    Server.new_session(server, "capabilities", command: {:argv, ["/bin/cat"]})

  {:ok, same_instance} =
    Control.with_connection(
      [server: server, session: {:existing, id}, lane: :host_qualified],
      fn control ->
        {:ok, connected} = Control.capabilities(control)
        connected.server_instance == report.server_instance and is_reference(connected.epoch)
      end
    )

  IO.puts(
    JSON.encode!(%{
      daemon: report.daemon_version,
      event_wait: event_wait,
      same_instance: same_instance
    })
  )
end)
```

<!-- /example -->

On tmux 3.8 it prints:

```text
{"daemon":"3.8","event_wait":"available","same_instance":true}
```

On tmux 3.3, `event_wait` is `"refused"`. That branch sends no event-wait
command. The server is private, so its empty configuration establishes the
bootstrap and control prerequisites below. `Server.with_owned/2` stops its
server and panes; `Control.with_connection/2` retires its client.

## Check a named primitive

`Capabilities.status/2` returns a decision; `supports?/2` returns a boolean;
`require/2` returns the supported decision or an error before dispatch. All
three are pure. Unknown IDs return `unknown_feature`; an unsupported decision
returns `unsupported_feature` with its required and observed versions.

| Feature ID | Native prerequisite | First release |
| --- | --- | --- |
| `event-wait` | Event subscriptions with `wait-for -E` | 3.8 |
| `event-wait-claim` | Consume a specific pending event waiter with `wait-for -E -w` | 3.8 |
| `format-argument-quote` | Quote an argument token with the `q/a` format modifier | 3.7 |
| `capture-trim-blank-cells` | Trim blank cells with `capture-pane -T` | 3.4 |

Each decision includes a link to pinned tmux source. These are tmux primitives,
not implemented Elixir Program operations. The registry covers known source
profiles from 3.3 through 3.8, including listed letter releases. Unknown patches,
prereleases and future releases return `unsupported_version` with the observed
release and minimum. Parsed ordering does not establish support for an unknown
profile. Runtime compatibility has its own [support cells](implementation.md).

## Preserve the observation boundary

- A `Server` remains an unbound descriptor. Discovery takes two bounded native
  observations and checks the daemon's OS identity around them. Its report
  does not reserve the socket or remove a later one-shot check/use race.
- Discovery reserves the native, unaliased `list-commands` bootstrap. On an
  existing server, keep that command unaliased throughout the call and exclude
  concurrent administrative configuration changes. Discovery does not inspect
  or repair configuration before trusting its bootstrap.
- A `Control` report stays on its already established epoch. Its field read
  inherits the connection's [host qualification](managed-control.md#before-you-start)
  for hooks, aliases and other writers. It does not reconnect or change
  transport. Mixed client/daemon connection limits remain in
  [implementation status](implementation.md).
- Both calls use one monotonic timeout, default 1000ms, with the existing
  bounded transport and cleanup errors. A timeout is not authority to replay.
- A report is captured data. Pure checks do not authenticate future commands
  or turn the report into an ownership token. A future managed Program API
  needs its own current capability and generation checks before effects.

The exhaustive command, flag, option and hook map remains in
[the release-map proposal](https://github.com/libtmux/libtmux-elixir/issues/81).
[Managed Program ownership](https://github.com/libtmux/libtmux-elixir/issues/89),
readiness/streaming and MCP are separate work.
