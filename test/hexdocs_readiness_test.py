"""Outer-loop release check: owned HTTP responses exercise real curl deadlines."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import threading
import time


requests = {}
release_stall = threading.Event()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests[self.path] = requests.get(self.path, 0) + 1
        status = 200
        if self.path == "/propagating" and requests[self.path] == 1:
            status = 404
        elif self.path == "/busy" and requests[self.path] == 1:
            status = 503
        elif self.path == "/missing":
            status = 404
        elif self.path == "/denied":
            status = 403
        elif self.path == "/stalled":
            self.send_response(200)
            self.send_header("Content-Length", "1")
            self.end_headers()
            release_stall.wait(5)
            return
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


script = os.environ.get(
    "HEXDOCS_CHECK_SCRIPT",
    str(Path(__file__).resolve().parents[1] / "scripts/wait_for_hexdocs.sh"),
)
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
thread.start()
try:
    for path, budget, expected, count in [
        ("/propagating", "4", 0, 2),
        ("/busy", "4", 0, 2),
        ("/denied", "4", 1, 1),
        ("/missing", "1", 1, 1),
        ("/stalled", "1", 1, 1),
    ]:
        started = time.monotonic()
        result = subprocess.run(
            ["bash", script, f"http://127.0.0.1:{server.server_port}{path}", budget],
            capture_output=True,
            text=True,
            timeout=int(budget) + 2,
        )
        elapsed = time.monotonic() - started
        assert result.returncode == expected, (path, result.returncode, result.stderr)
        assert requests.get(path) == count, (path, requests)
        if path == "/denied":
            assert "403" in result.stderr
        if path in ["/missing", "/stalled"]:
            assert "deadline" in result.stderr
        print(f"PASS {path}: {count} GETs, exit {expected}, {elapsed:.3f}s")
finally:
    release_stall.set()
    server.shutdown()
    server.server_close()
    thread.join(timeout=1)
    assert not thread.is_alive()
