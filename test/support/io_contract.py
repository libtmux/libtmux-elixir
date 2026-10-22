"""Qualify the candidate's private protocol and ordinary Linux ownership."""

import json
import fcntl
import os
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import sys
import time

HELPER = Path(os.environ["LIBTMUX_IO_HELPER"])
PYTHON = sys.executable


def string(value):
    value = os.fsencode(value)
    return struct.pack("!H", len(value)) + value


class Owned:
    def __init__(self, args, timeout=700, stdin=False):
        env = os.environ.copy()
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        self.process = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.send(b"O\x03" + bytes([stdin]) + struct.pack("!I", timeout) +
                  string(Path.cwd()) + struct.pack("!H", len(args)) + b"".join(map(string, args)) + b"\0\0")
        ready = self.receive()
        if ready[:1] != b"S":
            raise AssertionError(("missing spawn evidence", ready))
        self.pid = struct.unpack("!I", ready[1:])[0]

    def send(self, data):
        self.process.stdin.write(struct.pack("!H", len(data)) + data)

    def receive(self, seconds=0.75):
        end = time.monotonic() + seconds
        while True:
            if len(self.buffer) >= 2:
                size = struct.unpack_from("!H", self.buffer)[0]
                if len(self.buffer) >= 2 + size:
                    result = bytes(self.buffer[2:2 + size])
                    del self.buffer[:2 + size]
                    return result
            remaining = end - time.monotonic()
            assert remaining > 0 and self.selector.select(remaining), "helper response timeout"
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, ("helper exited", self.process.poll(), self.process.stderr.read())
            self.buffer += data

    def grant(self, stream, size=8192):
        self.send(b"R" + bytes([stream]) + struct.pack("!H", size))

    def drain(self):
        output = {1: bytearray(), 2: bytearray()}
        self.grant(1)
        self.grant(2)
        while True:
            message = self.receive()
            if message[:1] == b"D":
                stream = message[1]
                output[stream] += message[2:]
                self.grant(stream)
            elif message[:1] == b"Z":
                pass
            elif message[:1] == b"E":
                self.finish()
                return output, message
            else:
                raise AssertionError(message)

    def cancel(self):
        self.send(b"Q")
        while (message := self.receive())[:1] != b"E":
            assert message[:1] in [b"D", b"Z", b"A", b"C"], message
        self.finish()
        return message

    def finish(self, terminal_received=True):
        if terminal_received:
            self.send(b"T")
        assert self.process.wait(timeout=0.75) == 0, self.process.stderr.read()
        tail = bytes(self.buffer) + self.process.stdout.read()
        assert not tail, ("frames followed terminal", tail)
        self.selector.close()


def round_trip():
    child = Owned([PYTHON, "-c", "import os;os.write(1,b'out\\x00\\xff');os.write(2,b'err');raise SystemExit(7)"])
    output, terminal = child.drain()
    assert output == {1: b"out\0\xff", 2: b"err"}, output
    assert terminal == b"E\x00" + struct.pack("!I", 7), terminal


def terminal_ack():
    child = Owned(["/bin/true"])
    helper_fd = os.pidfd_open(child.process.pid)
    watched = selectors.DefaultSelector()
    watched.register(helper_fd, selectors.EVENT_READ)
    try:
        child.grant(1)
        child.grant(2)
        while (message := child.receive())[:1] != b"E":
            assert message[:1] == b"Z", message
        assert not watched.select(0.02), "helper exited before terminal acknowledgement"
        # Credits and cancellation already admitted by the owner may trail the proof.
        child.grant(1)
        child.send(b"Q")
        child.send(b"T")
        assert watched.select(0.75), "acknowledged helper did not exit"
        assert child.process.wait(timeout=0.75) == 0
        assert not bytes(child.buffer) + child.process.stdout.read(), "post-terminal output"
    finally:
        child.process.stdin.close()
        child.process.stdout.close()
        child.process.wait(timeout=0.75)
        child.selector.close()
        watched.close()
        os.close(helper_fd)


def credit_and_blocked_write():
    code = "import os\nwhile True:\n os.write(1,b'x'*8192)\n os.write(2,b'y'*8192)"
    child = Owned([PYTHON, "-c", code], stdin=True)
    child.grant(1)
    child.grant(2)
    first = [child.receive(), child.receive()]
    assert sorted(message[1] for message in first) == [1, 2], first
    assert all(message[:1] == b"D" and len(message) <= 8194 for message in first)
    assert not child.buffer and not child.selector.select(0), "uncredited output"
    child.send(b"W" + struct.pack("!I", 1) + b"a" * 4096)
    assert child.receive() == b"A" + struct.pack("!I", 1) + struct.pack("!H", 4096) + b"\0"
    child.send(b"W" + struct.pack("!I", 2) + b"b" * 8192)
    status = (Path("/proc") / str(child.process.pid) / "status").read_text()
    rss = next(line for line in status.splitlines() if line.startswith("VmRSS:"))
    assert not child.selector.select(0), "blocked stdin unexpectedly completed"
    child.send(b"Q")
    acknowledgments = []
    while (terminal := child.receive())[:1] != b"E":
        acknowledgments.append(terminal)
    assert b"A" + struct.pack("!I", 2) + struct.pack("!H", 4096) + b"\1" in acknowledgments, acknowledgments
    assert terminal[1] == 1, terminal
    pipe_sizes = [fcntl.fcntl(file, fcntl.F_GETPIPE_SZ) for file in [child.process.stdin, child.process.stdout]]
    child.finish()
    return {"read_grants": 2, "data_messages": 2, "helper_rss": rss,
            "parent_pipe_bytes": pipe_sizes, "partial_write_bytes": 4096}


def detached_descendant(parent_eof=False):
    code = """import os,signal
if os.fork()==0:
 os.setsid()
 if os.fork()!=0: os._exit(0)
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 os.write(1,(str(os.getpid())+'\\n').encode())
 while True: signal.pause()
while True: signal.pause()
"""
    child = Owned([PYTHON, "-c", code], timeout=0)
    child.grant(1)
    message = child.receive()
    assert message[:2] == b"D\x01", message
    grandchild = int(message[2:].strip())
    grandfd = os.pidfd_open(grandchild)
    if parent_eof:
        child.process.stdin.close()
        child.finish(terminal_received=False)
    else:
        child.cancel()
    watched = selectors.DefaultSelector()
    watched.register(grandfd, selectors.EVENT_READ)
    assert watched.select(0), "detached descendant survived"
    watched.close()
    os.close(grandfd)


def deadline():
    child = Owned([PYTHON, "-c", "import signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.pause()"], timeout=80)
    message = child.receive()
    assert message == b"E\x02" + struct.pack("!I", 137), message
    child.finish()


def late_write():
    code = "import os;os.read(0,1);os.write(1,b'exit');os._exit(7)"
    child = Owned([PYTHON, "-c", code], timeout=0, stdin=True)
    # The child is held on stdin; only the following write releases it.
    fd = os.pidfd_open(child.pid)
    watched = selectors.DefaultSelector()
    watched.register(fd, selectors.EVENT_READ)
    try:
        child.grant(1)
        child.send(b"W" + struct.pack("!I", 1) + b"g")
        frames = [child.receive(), child.receive()]
        assert b"D\1exit" in frames, frames
        assert watched.select(0.75), "released child did not exit"
        child.send(b"W" + struct.pack("!I", 2) + b"late")
        assert child.receive() == b"A" + struct.pack("!I", 2) + b"\0\0\1"
        child.send(b"C")
        assert child.receive() == b"C"
        output, terminal = child.drain()
        assert output == {1: b"", 2: b""}, output
        assert terminal == b"E\0" + struct.pack("!I", 7), terminal
    finally:
        child.process.stdin.close()
        child.process.stdout.close()
        child.process.wait(timeout=0.75)
        watched.close()
        os.close(fd)


def failures():
    frames = [b"\0\x01X", b"\0\0", struct.pack("!H", 32769)]
    for cwd, executable in [("/missing-cwd", PYTHON), (Path.cwd(), "/missing-executable")]:
        payload = b"O\x03\0" + struct.pack("!I", 500) + string(cwd) + struct.pack("!H", 1) + string(executable) + b"\0\0"
        frames.append(struct.pack("!H", len(payload)) + payload)
    for frame in frames:
        peer = Owned.__new__(Owned)
        peer.process = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        peer.selector = selectors.DefaultSelector()
        peer.selector.register(peer.process.stdout, selectors.EVENT_READ)
        peer.buffer = bytearray()
        helper_fd = os.pidfd_open(peer.process.pid)
        watched = selectors.DefaultSelector()
        watched.register(helper_fd, selectors.EVENT_READ)
        try:
            peer.process.stdin.write(frame)
            message = peer.receive()
            assert message[:1] == b"F", message
            peer.send(b"Q")
            assert not watched.select(0.02), "invalid header bypassed terminal acknowledgement"
            peer.finish()
        finally:
            peer.process.stdin.close()
            peer.process.stdout.close()
            peer.process.wait(timeout=0.75)
            watched.close()
            os.close(helper_fd)

    child = Owned([PYTHON, "-c", "import signal;signal.pause()"])
    child.grant(1)
    child.grant(1)
    assert child.receive()[:2] == b"F\x01"
    child.finish()


if __name__ == "__main__":
    started = time.monotonic()
    terminal_ack()
    round_trip()
    metrics = credit_and_blocked_write()
    detached_descendant()
    detached_descendant(parent_eof=True)
    deadline()
    late_write()
    failures()
    print(json.dumps({"status": "PASS", "seconds": round(time.monotonic() - started, 3), "metrics": metrics}))
