"""Run a controlled example on an owned Linux tmux server, or serve test fixtures."""

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
    pending = set(fds)
    deadline = time.monotonic() + 0.75
    emit({"kind": "watching"})
    try:
        while pending and (remaining := deadline - time.monotonic()) > 0:
            for fd, _ in poller.poll(max(1, int(remaining * 1000))):
                pending.remove(fd)
                poller.unregister(fd)
        if pending or time.monotonic() > deadline:
            raise TimeoutError("owned process exit was not observed before its deadline")
        emit({"kind": "exited"})
    finally:
        for fd in fds:
            os.close(fd)


def serve(executable, consumer=None):
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
        additional_panes = []

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
            failures = []
            clients_exited = True
            for process, fd in clients:
                try:
                    process.stdin.close()
                    if not exited(fd):
                        process.kill()
                        failures.append("control client needed forced termination")
                    process.wait()
                    clients_exited = clients_exited and exited(fd, 0)
                except Exception as error:
                    failures.append(str(error))
                    clients_exited = False
                finally:
                    for stream in [process.stdout, process.stderr]:
                        stream.close()
                    os.close(fd)
            clients.clear()
            if server.poll() is None:
                # The consumer has returned; no peer may create more example panes.
                if consumer is not None:
                    try:
                        panes = command([b"list-panes", b"-a", b"-F", b"#{pane_pid}"])
                        if panes.returncode != 0:
                            raise RuntimeError("cannot identify owned panes before teardown")
                        for pid in set(panes.stdout.split()):
                            try:
                                additional_panes.append(os.pidfd_open(int(pid)))
                            except ProcessLookupError:
                                pass
                    except Exception as error:
                        failures.append(str(error))
                try:
                    command([b"kill-server"])
                except Exception as error:
                    failures.append(str(error))
                if not exited(server_fd):
                    server.kill()
                    failures.append("server needed forced termination")
            status = server.wait()
            pane_exited = pane_fd is None or exited(pane_fd)
            for fd in additional_panes:
                pane_exited = exited(fd) and pane_exited
                os.close(fd)
            additional_panes.clear()
            if not pane_exited:
                failures.append("owned pane exit was not observed")
            return {"kind": "stopped", "server_exit": status, "pane_exited": pane_exited,
                    "clients_exited": clients_exited, "cleanup_errors": failures}

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
            if consumer is not None:
                caller_exit = None
                caller_error = None
                borrowed_survived = False
                try:
                    completed = subprocess.run(
                        [*consumer, executable, socket, "$0"], env=environment, timeout=10
                    )
                    caller_exit = completed.returncode
                    borrowed_survived = not exited(server_fd, 0) and not exited(pane_fd, 0)
                except Exception as error:
                    caller_error = str(error)
                finally:
                    cleanup = stop()
                cleanup.update(caller_exit=caller_exit, caller_error=caller_error,
                               borrowed_survived=borrowed_survived)
                emit(cleanup)
                failed = (caller_error is not None or not borrowed_survived or
                          cleanup["cleanup_errors"] or cleanup["server_exit"] != 0)
                return caller_exit if caller_exit else int(bool(failed))
            emit({"kind": "ready", "socket": socket, "server_pid": server.pid, "pane_pid": pane_pid})
            for line in sys.stdin:
                request = json.loads(line)
                if request["op"] == "stop":
                    stopped = stop()
                    if stopped["cleanup_errors"]:
                        raise RuntimeError(stopped["cleanup_errors"])
                    emit(stopped)
                    return
                if request["op"] == "attach":
                    emit(attach())
                    continue
                if request["op"] == "alive":
                    emit({"kind": "alive", "server": not exited(server_fd, 0),
                          "pane": not exited(pane_fd, 0)})
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
            for fd in additional_panes:
                os.close(fd)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--watch":
            watch(sys.argv[2:])
        elif sys.argv[1] == "--run":
            if len(sys.argv) < 4:
                raise ValueError("usage: owned_server.py --run TMUX COMMAND [ARG ...]")
            raise SystemExit(serve(os.path.abspath(sys.argv[2]), sys.argv[3:]))
        else:
            serve(sys.argv[1])
    except Exception as error:
        emit({"kind": "error", "message": str(error)[:2048]})
        raise
