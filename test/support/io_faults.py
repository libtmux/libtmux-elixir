"""Outer spike: exercise retirement interleavings and abandoned output."""
import json
import os
import selectors
import struct
import subprocess
import time
from io_contract import Owned, HELPER, PYTHON, string


def closed_reader():
    peer = Owned([PYTHON, "-c", "import signal;signal.pause()"], timeout=0)
    try:
        peer.process.stdout.close()
        assert peer.process.wait(timeout=0.4) == 0
    finally:
        peer.process.stdin.close()
        peer.process.wait(timeout=0.75)
        peer.selector.close()


def stalled_reader():
    process = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, bufsize=0, pipesize=4096)
    peer = Owned.__new__(Owned)
    peer.process = process
    peer.selector = selectors.DefaultSelector()
    peer.selector.register(process.stdout, selectors.EVENT_READ)
    peer.buffer = bytearray()
    args = [PYTHON, "-c", "import os\nwhile True:os.write(1,b'x'*8192)"]
    peer.send(b"O\2\0" + struct.pack("!I", 80) + string(os.getcwd()) +
              struct.pack("!H", len(args)) + b"".join(map(string, args)) + b"\0\0")
    assert peer.receive()[:1] == b"S"
    peer.grant(1)
    try:
        assert process.wait(timeout=0.95) == 124, "undelivered terminal needs a failure exit"
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait(timeout=0.75)
        peer.selector.close()


def startup_and_late_credit():
    for timeout in [1, 2, 10, 40]:
        peer = Owned.__new__(Owned)
        peer.process = subprocess.Popen([HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0)
        peer.selector = selectors.DefaultSelector()
        peer.selector.register(peer.process.stdout, selectors.EVENT_READ)
        peer.buffer = bytearray()
        args = [PYTHON, "-c", "import signal;signal.pause()"]
        init = b"O\2\0" + struct.pack("!I", timeout) + string(os.getcwd()) + struct.pack("!H", len(args)) + b"".join(map(string,args)) + b"\0\0"
        frame = struct.pack("!H", len(init)) + init + b"\0\1Q\0\4R\1\x20\0"
        peer.process.stdin.write(frame)
        terminal = None
        try:
            while terminal is None:
                message = peer.receive()
                if message[:1] == b"E": terminal = message
                else: assert message[:1] == b"S", message
            assert terminal[1] in [1, 2], terminal
            assert peer.process.wait(timeout=0.75) == 0
            assert not bytes(peer.buffer) + peer.process.stdout.read(), "post-terminal frames"
        finally:
            peer.process.stdin.close()
            peer.process.stdout.close()
            peer.process.wait(timeout=0.75)
            peer.selector.close()


results = []
for name, function in [("closed_reader", closed_reader), ("stalled_reader", stalled_reader),
                       ("startup_and_late_credit", startup_and_late_credit)]:
    start = time.monotonic()
    try:
        function()
        row = {"name": name, "status": "PASS"}
    except Exception as error:
        row = {"name": name, "status": "FAIL", "error": repr(error)}
    row["seconds"] = round(time.monotonic()-start, 3)
    results.append(row)
    print(json.dumps(row))
raise SystemExit(any(row["status"] != "PASS" for row in results))
