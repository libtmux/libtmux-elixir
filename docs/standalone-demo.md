# Run the standalone alpha demo

This self-contained example installs the published `0.0.1-alpha.4` package,
creates a private server, adds a pane and window, then prints
`demo: 2 windows, 3 panes`. It uses the alpha's explicit command API.
The [first task](first-task.md) shows how to observe an existing server;
[one-shot actions](one-shot-actions.md) introduces the domain helpers.

Save the program as `quickstart.exs`. Linux, Elixir 1.20.4 on OTP 29, a C11
compiler and tmux 3.3 or a later qualified version on `PATH` are required.
Its first run needs network access to install the package.

<!-- example: examples/quickstart.exs -->

```elixir
Mix.install([{:libtmux, "== 0.0.1-alpha.4"}])

alias LibTmux.{Command, Selection, Server, Snapshot}

for name <- ~w(TMUX TMUX_PANE), do: System.delete_env(name)
tmux = System.find_executable("tmux") || raise "tmux is not on PATH"
id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
dir = Path.join(System.tmp_dir!(), "libtmux-" <> id)
socket = Path.join(dir, "tmux.sock")
File.mkdir!(dir)
File.chmod!(dir, 0o700)

try do
  # libtmux works on a running server, so tmux itself starts the private one.
  create = ["new-session", "-d", "-s", "demo", "/bin/cat", "--"]
  {_, 0} = System.cmd(tmux, ["-S", socket, "-f", "/dev/null" | create])

  server = Server.new(executable: tmux, socket: socket)
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
  System.cmd(tmux, ["-S", socket, "kill-server"], stderr_to_stdout: true)
  File.rm_rf(dir)
end
```

<!-- /example -->

Run it outside a Mix project:

```console
$ elixir quickstart.exs
```

The program clears inherited tmux context and uses a unique socket directory.
Its `after` block requests server shutdown and removes that directory on
normal return or a raised exception. Killing the VM bypasses this block.
For supervised execution and explicit process-exit evidence, use the
[owned-server runner](owned-server.md). The standalone demo does not qualify
an arbitrary server for shared control.
