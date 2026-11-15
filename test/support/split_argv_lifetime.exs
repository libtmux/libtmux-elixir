# Qualifies packaged singleton argv after the creating BEAM exits.
#
# Usage: elixir -pa EBIN split_argv_lifetime.exs ELIXIR EBIN PACKAGE
#
# `tmux` must resolve on PATH. The script starts a private server through the
# packed library, splits panes from separate creator VMs that exit at once, and
# checks that the pane programs, respawn and the packaged helper still work.

[elixir, ebin, package] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)
Code.require_file("processes.ex", __DIR__)

defmodule SplitArgvLifetime do
  import Bitwise, only: [band: 2]
  alias LibTmux.{Command, Server}
  alias LibTmux.Test.Processes

  @creator ~S"""
  alias LibTmux.{Control, Pane, Ref, Server}
  [tmux, socket, session, lane, program, expected] = System.argv()
  {:ok, _} = Application.ensure_all_started(:libtmux)
  server = Server.new(executable: tmux, socket: socket, env: %{})
  {:ok, snapshot} = Server.snapshot(server)
  {:ok, ref} = Ref.from_observation(snapshot.panes["%0"])
  call = fn connection ->
    %{id: value} = Pane.split!(connection, ref, command: {:argv, [program]})
    value
  end
  id =
    case lane do
      "one_shot" -> call.(server)
      "control" ->
        {:ok, id} =
          Control.with_connection(
            [server: server, session: {:existing, session}, lane: :host_qualified], call)
        id
    end
  for module <- Application.spec(:libtmux, :modules) do
    true = Code.ensure_loaded?(module)
    path = module |> :code.which() |> List.to_string() |> Path.dirname() |> Path.expand()
    true = path == Path.expand(expected)
  end
  IO.puts(JSON.encode!(%{pane: id, helper: LibTmux.Transport.Native.executable()}))
  """

  def run(elixir, ebin, package) do
    tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

    Server.with_owned([executable: tmux], fn server ->
      {:ok, %{value: %{id: session}}} =
        Server.new_session(server, "fixture", command: {:argv, ["/bin/cat"]})

      directory = Path.dirname(server.socket)
      program = Path.join(directory, "argv-recorder")
      peer_path = Path.join(directory, "argv-peer")
      compile(program)

      tmux!(server, "set-environment", ["-t", session, "LIBTMUX_ARGV_SOCKET", peer_path])
      tmux!(server, "set-option", ["-w", "-t", "@0", "remain-on-exit", "on"])
      tmux!(server, "set-hook", ["-w", "-t", "@0", "pane-died", "wait-for -S argv-died"])

      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: peer_path})
      :ok = :socket.listen(listener)

      try do
        helper =
          for lane <- ["one_shot", "control"], reduce: nil do
            _ ->
              lane(lane, %{
                server: server,
                session: session,
                listener: listener,
                directory: directory,
                program: program,
                tmux: tmux,
                elixir: elixir,
                ebin: ebin,
                package: package
              })
          end

        invalid_helper_arguments(helper, program)
        removed_copy(server, listener, helper, program, directory)
      after
        :socket.close(listener)
      end
    end)

    IO.puts(
      JSON.encode!(%{
        singleton_argv: "ok",
        creating_beam_exited: true,
        respawn: "ok",
        removed_copy_respawn_exit: 1
      })
    )
  end

  defp lane(lane, context) do
    {output, 0} =
      System.cmd(
        context.elixir,
        [
          "-pa",
          context.ebin,
          "-e",
          @creator,
          "--",
          context.tmux,
          context.server.socket,
          context.session,
          lane,
          context.program,
          context.ebin
        ],
        cd: context.directory,
        stderr_to_stdout: true
      )

    %{"pane" => pane, "helper" => helper} = output |> String.trim() |> JSON.decode!()
    helper = Path.expand(helper)
    true = String.starts_with?(helper, Path.expand(context.package) <> "/")

    try do
      # System.cmd returned, so the creating BEAM has exited and its pipes are closed.
      observe(context.server, context.listener, pane, context.program)
      true = String.contains?(field(context.server, pane, "pane_start_command"), "--exec-one")
      tmux!(context.server, "respawn-pane", ["-t", pane])
      observe(context.server, context.listener, pane, context.program)
    after
      tmux!(context.server, "kill-pane", ["-t", pane])
    end

    helper
  end

  defp invalid_helper_arguments(helper, program) do
    for arguments <- [
          ["--wrong"],
          ["--exec-one"],
          ["--exec-one", ""],
          ["--exec-one", program, "extra"]
        ] do
      {"", 1} = System.cmd(helper, arguments, stderr_to_stdout: true)
    end
  end

  # Remove only a disposable copy; the extracted package stays intact.
  defp removed_copy(server, listener, helper, program, directory) do
    copied = Path.join(directory, "helper-copy")
    File.cp!(helper, copied)
    File.chmod!(copied, band(File.stat!(helper).mode, 0o777))

    pane =
      server
      |> tmux!("split-window", ["-d", "-P", "-F", ~S"#{pane_id}", copied, "--exec-one", program])
      |> String.trim()

    try do
      observe(server, listener, pane, program)
      File.rm!(copied)
      tmux!(server, "respawn-pane", ["-t", pane])
      tmux!(server, "wait-for", ["argv-died"])
      "1" = field(server, pane, "pane_dead_status")
    after
      tmux!(server, "kill-pane", ["-t", pane])
    end
  end

  defp observe(server, listener, pane, program) do
    {:ok, peer} = :socket.accept(listener, 5_000)
    {:ok, <<size::32>>} = :socket.recv(peer, 4, 5_000)
    true = size <= 131_072

    {:ok, <<argc::32, pid::32, parent::32, group::32, strings::binary>>} =
      :socket.recv(peer, size, 5_000)

    [^program | _] = :binary.split(strings, <<0>>, [:global])
    true = argc == 1
    true = Integer.to_string(pid) == field(server, pane, "pane_pid")
    true = Integer.to_string(parent) == field(server, pane, "pid")
    true = group == pid

    watched = Processes.identity!(pid)
    :ok = :socket.send(peer, <<23>>)
    tmux!(server, "wait-for", ["argv-died"])
    :ok = Processes.await_exit([watched], 5_000)
    :ok = :socket.close(peer)
    "23" = field(server, pane, "pane_dead_status")
  end

  defp field(server, pane, name),
    do:
      server
      |> tmux!("display-message", ["-p", "-t", pane, "\#{" <> name <> "}"])
      |> String.trim_trailing("\n")

  defp tmux!(server, name, args) do
    {:ok, %{stdout: stdout}} = Server.run(server, Command.new(name, args), timeout: 10_000)
    stdout
  end

  defp compile(program) do
    compiler =
      System.find_executable(System.get_env("CC", "cc")) || raise "a C compiler is required"

    {_, 0} =
      System.cmd(
        compiler,
        [
          "-std=c11",
          "-O2",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-o",
          program,
          Path.join(__DIR__, "split_argv.c")
        ],
        stderr_to_stdout: true
      )
  end
end

SplitArgvLifetime.run(elixir, ebin, package)
