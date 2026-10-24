# Run examples on an owned server

Use the shipped Linux runner for a private demonstration. It creates a
unique temporary socket and a foreground tmux server with an empty config,
clears inherited `TMUX` and `TMUX_PANE`, and starts one `cat` pane. It passes
the absolute executable, socket and `$0` session ID to the chosen program.
Python 3.9+ with Linux pidfd support is needed only for this runner.

From this source checkout, set `LIBTMUX_TMUX` to the absolute executable of
tmux 3.3 or a later qualified release, then run:

```console
$ python3 examples/owned_server.py --run "$LIBTMUX_TMUX" \
    mix run examples/managed_control.exs
```

Substitute `examples/capture_and_filter.exs` or
`examples/one_shot_actions.exs` or `examples/recover_command.exs` for the other
tasks. The runner accepts any caller command, but its cleanup contract covers
these controlled examples.
It is not a sandbox or a supervisor for arbitrary daemonizing programs.

The program borrows the server. On return, the runner verifies the original
server and pane survived, records process handles for remaining example
panes, stops only its owned server, and observes process exits. Caller failure
still enters teardown and preserves a nonzero exit status. Socket readiness
uses inotify; process retirement uses pidfd events. Neither uses a readiness
sleep. The final `stopped` JSON record reports teardown evidence.

To check the actual packed artifact outside the checkout, including the public
examples and caller-failure paths, run:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

## What qualifies this lane

The runner uses `-f /dev/null`, a private socket, controlled `cat` panes and
no other attached clients. The examples neither install hooks, override
command aliases, enter pane modes nor register output-producing subscriptions.
The admitted command names and default configuration are exercised against
each required tmux version. This controlled lifetime is the basis for the
examples' `lane: :host_qualified` declaration.

For another host, empty configuration alone is not a continuing guarantee.
The host must control configuration changes and competing clients throughout
the epoch, including effective hooks, overridden aliases, mode-dependent key
bindings, subscriptions and client-directed messages. Do not assert the flag
on an arbitrary interactive server merely because startup succeeds. Choose
explicit [one-shot execution](one-shot-actions.md) when that is the intended
transport. The library never silently removes hooks or changes transports.

Production server creation belongs to the host. `Server.new/1` describes a
server; `Control.start_link/1` attaches to an existing session. Neither owns
or kills that borrowed server. The [ownership guide](ownership.md) describes
library-owned clients and native helpers separately from server-owned jobs.

The [standalone alpha demo](standalone-demo.md) installs its own package and
creates a private server without this runner. It demonstrates the published
command API; its cleanup has a narrower contract.
