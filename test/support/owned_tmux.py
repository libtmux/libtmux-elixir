"""Own a foreground Linux tmux fixture and report verified process exit."""

import base64
import ctypes
import json
import os
import select
import struct
import subprocess
import sys
import tempfile
import time


def emit(value):
    print(json.dumps(value), flush=True)


def exited(fd, milliseconds=750):
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    return bool(poller.poll(milliseconds))


def wait_listening(fd):
    # tmux chmods its socket after listen; IN_ATTRIB closes the bind/listen race.
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    deadline = time.monotonic() + 0.75
    while (remaining := deadline - time.monotonic()) > 0:
        if not poller.poll(max(1, int(remaining * 1000))):
            break
        data = os.read(fd, 65536)
        offset = 0
        while offset < len(data):
            _, mask, _, length = struct.unpack_from("iIII", data, offset)
            name = data[offset + 16 : offset + 16 + length].split(b"\0", 1)[0]
            if mask & 4 and name == b"s":
                return
            offset += 16 + length
    raise TimeoutError("owned tmux did not report listening")


def watch(pids):
    fds = [os.pidfd_open(int(pid)) for pid in pids]
    poller = select.poll()
    for fd in fds:
        poller.register(fd, select.POLLIN)
    emit({"kind": "watching"})
    pending = set(fds)
    deadline = time.monotonic() + 0.75
    try:
        while pending and (remaining := deadline - time.monotonic()) > 0:
            for fd, _ in poller.poll(max(1, int(remaining * 1000))):
                pending.remove(fd)
                poller.unregister(fd)
        if pending:
            raise TimeoutError("owned fixture processes remained alive")
        emit({"kind": "exited"})
    finally:
        for fd in fds:
            os.close(fd)


def serve(executable):
    environment = os.environ.copy()
    environment.pop("TMUX", None)
    environment.pop("TMUX_PANE", None)
    with tempfile.TemporaryDirectory(prefix="ltx-", dir="/tmp") as directory:
        socket = os.path.join(directory, "s")
        libc = ctypes.CDLL(None, use_errno=True)
        notify = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if notify < 0 or libc.inotify_add_watch(notify, os.fsencode(directory), 4) < 0:
            raise OSError(ctypes.get_errno(), "inotify fixture setup failed")
        server = None
        server_fd = None
        pane_fd = None
        clients = []

        def command(argv):
            return subprocess.run(
                [os.fsencode(executable), b"-N", b"-S", os.fsencode(socket), *argv],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=0.75,
                check=False,
            )

        def stop():
            if server is None:
                return None
            for process, fd in clients:
                process.stdin.close()
                if not exited(fd):
                    process.kill()
                    process.wait()
                    raise TimeoutError("owned control client did not exit after EOF")
                process.wait()
                process.stdout.close()
                process.stderr.close()
                os.close(fd)
            clients.clear()
            if server.poll() is None:
                command([b"kill-server"])
                if not exited(server_fd):
                    server.kill()
                    raise TimeoutError("owned server did not exit after kill-server")
            status = server.wait()
            pane_exited = pane_fd is None or exited(pane_fd)
            if not pane_exited:
                raise TimeoutError("owned pane process remained alive")
            return {"kind": "stopped", "server_exit": status, "pane_exited": pane_exited,
                    "clients_exited": True}

        def attach():
            process = subprocess.Popen(
                [executable, "-N", "-C", "-S", socket, "attach-session", "-t", "$0",
                 "-f", "no-output,ignore-size"], env=environment, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            fd = os.pidfd_open(process.pid)
            clients.append((process, fd))
            poller = select.poll()
            poller.register(process.stdout, select.POLLIN)
            data = bytearray()
            deadline = time.monotonic() + 0.75
            while (remaining := deadline - time.monotonic()) > 0:
                if not poller.poll(max(1, int(remaining * 1000))):
                    break
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("owned client exited before attach acknowledgment")
                data += chunk
                if len(data) > 65536:
                    raise RuntimeError("owned client startup exceeded byte limit")
                if b"\n%error " in data:
                    raise RuntimeError("owned client attach failed")
                if b"\n%end " in data:
                    return {"kind": "attached", "pid": process.pid}
            raise TimeoutError("owned client did not acknowledge attachment")

        try:
            server = subprocess.Popen(
                [executable, "-D", "-S", socket, "-f", "/dev/null"],
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            server_fd = os.pidfd_open(server.pid)
            wait_listening(notify)
            os.close(notify)
            notify = None
            created = command(
                [b"new-session", b"-d", b"-s", b"fixture", b"-P", b"-F", b"#{pane_pid}", b"/bin/cat", b"--"]
            )
            if created.returncode != 0:
                raise RuntimeError(created.stdout[:1024])
            pane_pid = int(created.stdout.strip())
            pane_fd = os.pidfd_open(pane_pid)
            emit({"kind": "ready", "socket": socket, "server_pid": server.pid, "pane_pid": pane_pid})
            for line in sys.stdin:
                request = json.loads(line)
                if request["op"] == "stop":
                    emit(stop())
                    return
                if request["op"] == "attach":
                    emit(attach())
                    continue
                if request["op"] != "command":
                    raise ValueError("unknown fixture request")
                argv = [base64.b64decode(value, validate=True) for value in request["argv"]]
                result = command(argv)
                emit({"kind": "reply", "status": result.returncode, "data": base64.b64encode(result.stdout).decode("ascii")})
        finally:
            if server is not None and server.poll() is None:
                try:
                    stop()
                finally:
                    if server.poll() is None:
                        server.kill()
                        server.wait()
            for fd in [notify, server_fd, pane_fd]:
                if fd is not None:
                    os.close(fd)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--watch":
            watch(sys.argv[2:])
        else:
            serve(sys.argv[1])
    except Exception as error:
        emit({"kind": "error", "message": str(error)[:2048]})
        raise
