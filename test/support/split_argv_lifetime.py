"""Qualify packaged singleton argv after the creating BEAM exits."""

import json
import os
from pathlib import Path
import select
import shutil
import socket
import struct
import subprocess
import sys

elixir, ebin, package, tmux, address, session = sys.argv[1:]
directory = Path(address).parent
program = directory / "argv-recorder"
peer_path = directory / "argv-peer"
subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-o", str(program), str(Path(__file__).with_name("split_argv.c"))], check=True)


def command(*argv):
    return subprocess.check_output([tmux, "-N", "-S", address, *argv], timeout=0.75)


def field(pane, name):
    return command("display-message", "-p", "-t", pane, "#{" + name + "}").rstrip(b"\n")


def receive(peer, size):
    data = b""
    while len(data) < size:
        part = peer.recv(size - len(data))
        if not part:
            raise RuntimeError("argv recorder closed before its report")
        data += part
    return data


def observe_program(listener, pane):
    peer, _ = listener.accept()
    with peer:
        peer.settimeout(0.75)
        size, = struct.unpack("!I", receive(peer, 4))
        assert size <= 131072
        data = receive(peer, size)
        argc, pid, parent, group = struct.unpack("!IIII", data[:16])
        assert argc == 1 and data[16:].split(b"\0")[0] == os.fsencode(program)
        assert pid == int(field(pane, "pane_pid")) and parent == int(field(pane, "pid"))
        assert group == pid
        fd = os.pidfd_open(pid)
        try:
            peer.sendall(bytes([23]))
            command("wait-for", "argv-died")
            poller = select.poll()
            poller.register(fd, select.POLLIN)
            assert poller.poll(750), "pane program exit was not observed"
        finally:
            os.close(fd)
    assert field(pane, "pane_dead_status") == b"23"


code = r'''
alias LibTmux.{Action, Control, Pane, Ref, Server}
[tmux, socket, session, lane, program, expected] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)
server = Server.new(executable: tmux, socket: socket, env: %{})
{:ok, snapshot} = Server.snapshot(server)
{:ok, ref} = Ref.from_observation(snapshot.panes["%0"])
call = fn connection -> Pane.split!(connection, ref, command: {:argv, [program]}) |> Action.value!() end
id = case lane do
  "one_shot" -> call.(server)
  "control" ->
    {:ok, id} = Control.with_connection([server: server, session: {:existing, session}, lane: :host_qualified], call)
    id
end
for module <- Application.spec(:libtmux, :modules) do
  true = Code.ensure_loaded?(module)
  path = module |> :code.which() |> List.to_string() |> Path.dirname() |> Path.expand()
  true = path == Path.expand(expected)
end
IO.puts(JSON.encode!(%{pane: id, helper: LibTmux.Transport.Native.executable()}))
'''

command("set-environment", "-t", session, "LIBTMUX_ARGV_SOCKET", str(peer_path))
command("set-option", "-w", "-t", "@0", "remain-on-exit", "on")
command("set-hook", "-w", "-t", "@0", "pane-died", "wait-for -S argv-died")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
    listener.bind(str(peer_path))
    listener.listen()
    listener.settimeout(0.75)
    for lane in ("one_shot", "control"):
        result = subprocess.run([elixir, "-pa", ebin, "-e", code, "--", tmux, address,
                                 session, lane, str(program), ebin],
                                cwd=directory, capture_output=True, timeout=0.95, check=True)
        assert not result.stderr, result.stderr
        created = json.loads(result.stdout)
        helper = Path(created["helper"]).resolve(strict=True)
        assert helper.is_relative_to(Path(package).resolve())
        pane = created["pane"]
        try:
            # subprocess.run has observed the creating BEAM's exit.
            observe_program(listener, pane)
            assert b"--exec-one" in field(pane, "pane_start_command")
            command("respawn-pane", "-t", pane)
            observe_program(listener, pane)
        finally:
            command("kill-pane", "-t", pane)

    for arguments in (["--wrong"], ["--exec-one"], ["--exec-one", ""],
                      ["--exec-one", str(program), "extra"]):
        failed = subprocess.run([str(helper), *arguments], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=0.75)
        assert failed.returncode == 1 and not failed.stdout and not failed.stderr

    # Remove only a disposable copy; the extracted package stays intact.
    copied = directory / "helper-copy"
    shutil.copy2(helper, copied)
    pane = command("split-window", "-d", "-P", "-F", "#{pane_id}",
                   str(copied), "--exec-one", str(program)).decode().strip()
    try:
        observe_program(listener, pane)
        copied.unlink()
        command("respawn-pane", "-t", pane)
        command("wait-for", "argv-died")
        assert field(pane, "pane_dead_status") == b"1"
    finally:
        command("kill-pane", "-t", pane)

print(json.dumps({"singleton_argv": "ok", "creating_beam_exited": True,
                  "respawn": "ok", "removed_copy_respawn_exit": 1}))
