# Owned I/O helper

`owned_io.c` is part of libtmux, built from source by Mix. It is a separate
Linux executable, with no NIF or third-party library. Its no-argument transport
mode requires Linux process/pipe APIs and a mounted `/proc`. It owns one
ordinary finite child tree and uses nonblocking pipes and subreaper adoption.
It is not a sandbox.

The private `--exec-one PROGRAM` mode preserves singleton argv for pane splits.
Before transport initialization, it replaces itself through `execvp` with
`[PROGRAM]`, retaining tmux's environment, descriptors and cwd. It forks no
child and provides no transport ownership/cleanup protocol; tmux owns the
pane process. Exec failure exits 1, as tmux's argv path does. Other argument
shapes are rejected. tmux retains this helper path for commandless respawn,
so removing or relocating the installation can break that later operation.

## Private protocol

Messages use a two-byte big-endian length. Input payloads are at most
32,768 bytes. Child output enters separate pipes and cannot write the
helper's protocol descriptor. Each stdout/stderr credit allows one response
with at most 8,192 data bytes. The fixed output queue has eight slots.

| Input | Payload after type |
|---|---|
| `O` | Version `3`, stdin-open byte, timeout milliseconds (u32), cwd string, argv count (u16) and strings, environment count (u16) and `key=value` strings |
| `R` | Stream byte (`1` stdout, `2` stderr), credit bytes (u16) |
| `W` | Request ID (u32), one nonempty bounded write |
| `C` | Close child stdin after the acknowledged write |
| `Q` | Stop and retire the owned tree |
| `T` | Acknowledge terminal `E` or `F` kind 1–3; send no further input |

Strings use a u16 byte length and reject NUL. The whole initialization
payload has a 32 KiB ceiling. Argv permits 2,048 entries including the
executable; environment remains limited to 256 entries. Target values pass
directly to child `execve`; empty and arbitrary non-NUL values remain bytes. They do
not configure the helper's startup.

| Output | Meaning |
|---|---|
| `S` + pid (u32) | Exec pipe closed successfully; diagnostic PID without a live-PID reservation |
| `D` + stream + bytes | One credited chunk |
| `Z` + stream | Credited stream EOF |
| `A` + request ID + delivered bytes (u16) + failed byte | Child-pipe write outcome; not command completion |
| `C` | Child stdin closed |
| `E` + reason + exit status (u32) | Owned children reaped; reason `0` natural, `1` stop, `2` timeout, `3` failure |
| `F` + kind + errno (u32) | Kind `1` protocol/setup, `2` exec, `3` I/O; kind `4` reports incomplete cleanup |

`E` and `F` kinds 1–3 follow child retirement. Kind 4 does not prove
retirement and must not be acknowledged. After terminal proof the helper
discards earlier credits, writes and stops, keeping its input open until
`T` arrives. The owner then sends no further input and waits for the actual
helper exit. This prevents a late cancellation from racing helper exit and
destroying the Port's exit-status evidence. No output frame follows terminal
proof. Exit 124 reports missing terminal delivery or acknowledgement after
the existing 750 ms delivery allowance. A helper exit alone is not a
successful command result.

A zero or oversized length is a fatal protocol error. The helper discards
that invalid two-byte header and resets to a fresh header so the owner can
acknowledge terminal proof. It does not recover the rejected payload or
resume child I/O. Further malformed data cannot extend the delivery deadline.

## Ownership limits

The parent pipe remains observed while output or child input is blocked.
Parent EOF and handled termination signals initiate cleanup. The helper
signals its process group before reaping the leader, then kills and reaps
adopted direct children. This helper is their sole reaper, preventing
numeric child PID reuse during signalling.

Cleanup and terminal delivery use 750 ms allowances. An uninterruptible
child can remain owned beyond that allowance; the helper reports incomplete
cleanup and retains ownership until it can reap. Helper SIGKILL, hostile
indefinite forks and host compromise have no unconditional cleanup promise.
Server-owned tmux jobs are outside a borrowed client's ancestry. Tmux
clients need `-N`; intentional server creation needs a separate lifecycle.
