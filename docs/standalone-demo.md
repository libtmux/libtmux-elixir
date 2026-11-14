# Run the standalone demo

This self-contained program installs the published package, creates a private
server, adds a pane and a window, and prints `demo: 2 windows, 3 panes`. It
uses the explicit command API.

It needs Linux, Elixir 1.20 on OTP 29, a C compiler and tmux 3.3 or newer on
`PATH`. The first run needs network access to install the package. Save it as
`quickstart.exs`:

<!-- example: examples/quickstart.exs -->

```elixir
Mix.install([{:libtmux, "~> 0.1"}])

alias LibTmux.{Command, Selection, Server, Snapshot}

for name <- ~w(TMUX TMUX_PANE), do: System.delete_env(name)
tmux = System.find_executable("tmux") || raise "tmux is not on PATH"
id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
dir = Path.join(System.tmp_dir!(), "libtmux-" <> id)
socket = Path.join(dir, "tmux.sock")
File.mkdir!(dir)
File.chmod!(dir, 0o700)
server = Server.new(executable: tmux, socket: socket)

try do
  # libtmux works on a running server, so tmux itself starts the private one.
  create = ["new-session", "-d", "-s", "demo", "/bin/cat", "--"]
  {_, 0} = System.cmd(tmux, ["-S", socket, "-f", "/dev/null" | create])

  split = Command.new("split-window", ["-t", "demo", "/bin/cat", "--"])
  logs = Command.new("new-window", ~w(-t demo -n logs /bin/cat --))
  {:ok, _} = Server.run(server, split)
  {:ok, _} = Server.run(server, logs)

  snapshot = Server.snapshot!(server)
  session = snapshot |> Snapshot.sessions() |> Selection.one!()
  windows = snapshot |> Snapshot.windows() |> Selection.size()
  panes = snapshot |> Snapshot.panes() |> Selection.size()
  IO.puts("#{session.name}: #{windows} windows, #{panes} panes")
after
  Server.run(server, Command.new("kill-server", []))
  File.rm_rf(dir)
end
```

<!-- /example -->

Run it outside a Mix project:

```console
$ elixir quickstart.exs
```

- The program clears inherited tmux context and uses a unique socket
  directory.
- Its `after` block sends `kill-server` through `Server.run/3` and removes the
  directory, on a normal return or a raised exception. Killing the VM skips
  it.
- libtmux never starts a server, so the program starts one with tmux itself.
- For supervised execution and process-exit evidence, use the
  [owned-server runner](owned-server.md). The demo does not qualify an
  arbitrary server for shared control.

Next: [observe an existing server](first-task.md), or the domain helpers in
[one-shot actions](one-shot-actions.md).
