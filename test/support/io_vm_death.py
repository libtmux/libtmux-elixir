"""Verify helper/descendant retirement after owner or VM death using pidfds."""
import json
import os
import selectors
import signal
import subprocess
import sys
import time

mode, erl, beam_directory = sys.argv[1:]
command = [erl, "-noshell", "-pa", beam_directory, "-s", "libtmux_io_vm", "run"]
if mode == "owner": command += ["-extra", "owner"]
unrelated = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
vm_environment = os.environ.copy()
vm_environment["ERL_FLAGS"] = "+S 1:1 +A 1 +SDcpu 1 +SDio 1"
vm = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=vm_environment)
watched = selectors.DefaultSelector()
fds = []
started = time.monotonic()
try:
    watched.register(vm.stdout, selectors.EVENT_READ)
    ready_deadline = started + 0.95
    ready = b""
    while b"\n" not in ready:
        remaining = ready_deadline - time.monotonic()
        assert remaining > 0 and watched.select(remaining), "VM did not report readiness"
        chunk = os.read(vm.stdout.fileno(), 256 - len(ready))
        assert chunk, "VM exited before readiness"
        ready += chunk
        assert len(ready) < 256, "VM readiness exceeded its byte bound"
    readiness_seconds = time.monotonic() - started
    processes = list(map(int, ready.split()))
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
                      "unrelated_survived": True, "readiness_seconds": round(readiness_seconds, 3),
                      "seconds": round(time.monotonic()-started,3)}))
finally:
    watched.close()
    for fd in fds: os.close(fd)
    if vm.poll() is None: vm.kill(); vm.wait(timeout=0.75)
    unrelated.stdin.close()
    unrelated.wait(timeout=0.75)
