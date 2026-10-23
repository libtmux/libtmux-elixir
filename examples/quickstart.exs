Mix.install([{:libtmux, "== 0.0.1-alpha.1"}])

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
