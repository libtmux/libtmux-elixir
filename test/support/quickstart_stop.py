"""Observe exact quickstart processes around its requested kill-server."""

import json
import os
import select
import subprocess
import sys
import time

tmux, record, socket, *arguments = sys.argv[1:]
environment = os.environ.copy()
environment.pop("TMUX", None)
environment.pop("TMUX_PANE", None)


def query(*command):
    return subprocess.check_output(
        [tmux, "-S", socket, *command], env=environment, timeout=0.75
    ).decode().splitlines()


server = int(query("display-message", "-p", "#{pid}")[0])
panes = [int(pid) for pid in query("list-panes", "-a", "-F", "#{pane_pid}")]
assert panes
fds = [os.pidfd_open(pid) for pid in {server, *panes}]
try:
    poller = select.poll()
    for fd in fds:
        poller.register(fd, select.POLLIN)
    # A missing kill-server call never reaches this watcher. It does not
    # perform fallback cleanup or conceal a live server from the test.
    result = subprocess.run([tmux, *arguments], env=environment, timeout=0.75)
    assert result.returncode == 0
    pending = set(fds)
    deadline = time.monotonic() + 0.75
    while pending and (remaining := deadline - time.monotonic()) > 0:
        for fd, _ in poller.poll(max(1, int(remaining * 1000))):
            pending.remove(fd)
            poller.unregister(fd)
    assert not pending, "quickstart process survived kill-server"
    with open(record, "a") as output:
        output.write(json.dumps({"server_exited": True, "panes_exited": len(panes)}) + "\n")
finally:
    for fd in fds:
        os.close(fd)
