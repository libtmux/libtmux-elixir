"""Verify helper/descendant retirement after owner or VM death using pidfds."""
import json
import os
import selectors
import signal
import subprocess
import sys
import time

mode, erl, beam_directory = sys.argv[1:]
command = [erl, "+S", "4:4", "-noshell", "-pa", beam_directory, "-s", "libtmux_io_vm", "run"]
if mode == "owner": command += ["-extra", "owner"]
unrelated = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
vm = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
watched = selectors.DefaultSelector()
fds = []
started = time.monotonic()
try:
    watched.register(vm.stdout, selectors.EVENT_READ)
    assert watched.select(0.95), "VM did not report readiness"
    processes = list(map(int, vm.stdout.readline().split()))
    assert len(processes) == 3, processes
    watched.unregister(vm.stdout)
    for pid in processes:
        fd = os.pidfd_open(pid)
        fds.append(fd)
        watched.register(fd, selectors.EVENT_READ)
    if mode == "owner":
        vm.stdin.write(b"kill\n")
        vm.stdin.flush()
    else:
        vm.kill()
        assert vm.wait(timeout=0.75) == -signal.SIGKILL
    deadline = time.monotonic() + 0.75
    pending = set(fds)
    while pending:
        remaining = deadline - time.monotonic()
        assert remaining > 0, "owned processes survived owner or VM death"
        for event, _ in watched.select(remaining):
            watched.unregister(event.fd)
            pending.remove(event.fd)
    assert unrelated.poll() is None, "unrelated process was killed"
    if mode == "owner": assert vm.poll() is None, "VM died during owner-only test"
    print(json.dumps({"status": "PASS", "mode": mode, "process_count": len(fds),
                      "unrelated_survived": True, "seconds": round(time.monotonic()-started,3)}))
finally:
    watched.close()
    for fd in fds: os.close(fd)
    if vm.poll() is None: vm.kill(); vm.wait(timeout=0.75)
    unrelated.stdin.close()
    unrelated.wait(timeout=0.75)
