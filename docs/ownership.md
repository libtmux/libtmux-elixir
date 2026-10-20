# One-shot process ownership

`LibTmux.Transport.OneShot.run/3` runs an absolute executable and argv on
Linux without a shell. It returns bytes, process exit status and cleanup
evidence separately. A nonzero process exit is still a completed transport
result; the tmux command layer must interpret that status. The domain
client and persistent transport remain planned.

The native helper supplies receive credits that an ordinary OTP Port
lacks. It reads each stdout/stderr pipe only against one bounded credit;
its control pipe stays responsive while output or stdin is blocked. A
capture limit after delivery cannot bound an upstream mailbox while its
owner is descheduled.

## Limits and results

Default ceilings are 1 MiB stdout, 64 KiB stderr and 4096 retained chunks.
Byte limits may be 0–16 MiB per stream; chunk limits may be 1–65,536.
Encoded cwd, argv and environment together fit a 32 KiB initialization
payload. Argv and environment each have at most 256 entries, including
argv's executable. Target environment values preserve empty strings and
non-NUL bytes; inherited tmux context is removed. Requested variables apply
to child `execve`; the helper inherits the trusted host environment.

The timeout defaults to 5000 ms and is at most 600,000 ms. A caller can
pass an existing `LibTmux.Deadline` instead. Admission, startup and capture
share that budget. Cleanup has a separate allowance up to 750 ms. Expiry
never turns partial output into success.

Overload stops the owned producer and returns a structured error with a
bounded prefix. `cleanup: :retired` requires private child-retirement evidence
and helper exit. Missing proof stays `:unknown`. An exit status or retryable
error never authorizes replay.

The worker monitors its caller. Caller death initiates cleanup; worker/VM
death closes the helper's parent pipe. Caller settlement and retirement
remain separate. Closing the reply alias also removes an already-delivered
result, releasing captured bytes from the caller's mailbox.

## Accounting and scope

Per-call bounds cover output bytes, chunk metadata, encoded input and
private frames. Captured chunks can coexist with an assembled result;
account for both copies. The helper has fixed input, queue and write
buffers, bounded initialization allocations, 8 KiB child pipes and a 4 KiB
signal pipe. Parent pipes and Port delivery add finite buffers outside the
capture byte count. See [the protocol](../c_src/README.md).

This primitive has one request per worker and no shared request queue.
Applications creating many independent callers need admission limits at
their host/server boundary. A per-call ceiling is not a global memory
ceiling. Ordinary finite descendants are killed and reaped. Uninterruptible
tasks, helper SIGKILL, hostile escape and host compromise are outside that
guarantee; incomplete cleanup retains uncertainty and ownership.

Use explicit sockets and `-N` for borrowed tmux servers. Retiring a client
must not stop a borrowed server. Intentional server creation and server-owned
jobs need their own ownership boundaries.

## Building and distribution

Mix builds the shipped C source with a C11 compiler and Linux headers.
`CC` may name one compiler executable. Generated binaries are excluded from
Hex archives and rebuilt during dependency compilation. No third-party
runtime package or NIF is added.

Packed-core checks must compile and execute outside the checkout.
Workspace/MCP escript extraction and helper discovery still need their
installed-consumer checks; the current path expects an unpacked application
`priv` directory. Other platforms remain unqualified.
