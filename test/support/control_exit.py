"""Disconnect one owned client through its pidfd and observe its helper's exit."""
import hashlib
import json
import os
import selectors
import signal
import sys
import time


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    helper_pid, client_pid = [int(pid) for pid in sys.argv[1:]]
    helper, client = [os.pidfd_open(pid) for pid in [helper_pid, client_pid]]
    try:
        identities = {}
        for name, pid, handle in [("helper", helper_pid, helper), ("client", client_pid, client)]:
            signal.pidfd_send_signal(handle, 0)
            with open(f"/proc/{pid}/exe", "rb") as executable:
                identities[name + "_sha256"] = hashlib.sha256(executable.read()).hexdigest()
            signal.pidfd_send_signal(handle, 0)
            identities[name + "_pid"] = pid
        emit({"kind": "ready", **identities})
        if sys.stdin.readline() != "terminate\n":
            raise RuntimeError("missing owned client termination request")
        started = time.monotonic()
        signal.pidfd_send_signal(client, signal.SIGTERM)
        with selectors.DefaultSelector() as watcher:
            watcher.register(helper, selectors.EVENT_READ)
            watcher.register(client, selectors.EVENT_READ)
            while watcher.get_map():
                remaining = 0.750 - (time.monotonic() - started)
                if remaining <= 0:
                    raise RuntimeError("owned client/helper did not exit within 750ms")
                for key, _events in watcher.select(remaining):
                    if time.monotonic() - started >= 0.750:
                        raise RuntimeError("exit was observed after the original 750ms cutoff")
                    watcher.unregister(key.fd)
        emit({"kind": "exited", "milliseconds": (time.monotonic() - started) * 1000})
    finally:
        os.close(helper)
        os.close(client)


if __name__ == "__main__":
    main()
