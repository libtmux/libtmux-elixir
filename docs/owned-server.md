# Run examples on an owned server

The shipped Linux runner gives an example a private tmux server. It:

- creates a unique temporary socket and a foreground tmux server with an
  empty config
- clears inherited `TMUX` and `TMUX_PANE`
- starts one `cat` pane
- passes the absolute executable, socket and `$0` session ID to your program

It needs Python 3.9+ with Linux pidfd support, and nothing else. From this
source checkout, set `LIBTMUX_TMUX` to the absolute path of tmux 3.3 or
newer, then run:

```console
$ python3 examples/owned_server.py --run "$LIBTMUX_TMUX" \
    mix run examples/managed_control.exs
```

Swap in `examples/capture_and_filter.exs`, `examples/filtering.exs`,
`examples/one_shot_actions.exs` or `examples/recover_command.exs` for the other
tasks.

- The runner accepts any command, but its cleanup covers these controlled
  examples.
- It is not a sandbox or a supervisor for programs that daemonize.

Your program borrows the server. When it returns, the runner:

- checks that the original server and pane survived
- records process handles for any remaining example panes
- stops only its own server and observes the process exits

A failing program still reaches teardown, and its nonzero exit status is
kept. Socket readiness uses inotify and process retirement uses pidfd
events, so no step sleeps. The final `stopped` JSON record reports the
teardown evidence.

To check the packed artifact outside the checkout, including the public
examples and failure paths, run:

```console
$ MIX_ENV=test mix run scripts/check_package.exs --examples
```

## What qualifies this lane

- The runner uses `-f /dev/null`, a private socket, controlled `cat` panes and
  no other attached clients.
- The examples install no hooks, override no command aliases, enter no pane
  modes and register no output-producing subscriptions.
- The admitted command names and default configuration run against each
  required tmux release.
- That controlled lifetime is why the examples declare
  `lane: :host_qualified`.

## On another host

- An empty configuration alone is not a continuing guarantee.
- The host must control configuration changes and competing clients for the
  whole epoch: effective hooks, overridden aliases, mode-dependent key
  bindings, subscriptions and client-directed messages.
- Do not set the flag on an arbitrary interactive server because startup
  succeeded. Use [one-shot execution](one-shot-actions.md) if that is the
  transport you want.
- The library never silently removes hooks or changes transports.

## Who owns the server

- Server creation belongs to the host. `Server.new/1` describes a server and
  `Control.start_link/1` attaches to an existing session. Neither owns or
  kills that borrowed server.
- The [ownership guide](ownership.md) covers library-owned clients and native
  helpers apart from server-owned jobs.
- The [standalone demo](standalone-demo.md) installs the package and creates a
  private server without this runner. Its cleanup has a narrower contract.
