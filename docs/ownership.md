# One-shot process ownership

`LibTmux.Transport.OneShot.run/3` runs an absolute executable and argv on
Linux without a shell. It returns bytes, process exit status and cleanup
evidence separately. A nonzero process exit is still a completed transport
result; the tmux command layer must interpret that status. The domain
client and public persistent transport remain under implementation.

The native helper supplies receive credits that an ordinary OTP Port
lacks. It reads each stdout/stderr pipe only against one bounded credit;
its control pipe stays responsive while output or stdin is blocked. A
capture limit after delivery cannot bound an upstream mailbox while its
owner is descheduled.

## Limits and results

Default ceilings are 1 MiB stdout, 64 KiB stderr and 4096 retained chunks.
Byte limits may be 0–16 MiB per stream; chunk limits may be 1–65,536.
`max_total_bytes` limits both streams together to 0–32 MiB; its default is
the sum of the stream limits. The retained prefix obeys both ceilings.
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

The worker acknowledges terminal child-retirement proof before the helper
exits. The helper keeps its input open while earlier cancellation or read
credits drain; after acknowledgement the worker writes nothing further.
This preserves the helper's separate exit-status evidence. Missing
acknowledgement uses the existing 750 ms delivery allowance.

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

## Persistent connection components

The internal Guardian owns one native helper and monitors its Manager and
router independently. It grants one stdout credit only after router demand,
caps stderr at 8 KiB and 64 chunks, and acknowledges one write fragment at a
time. A fragment fits 8 KiB; a complete rendered command fits 64 KiB. The
writer rechecks the consumed publication lease, original deadline and epoch.
A partial line keeps its writer until the newline is acknowledged or the
epoch closes. Completed slots retain their generation to reject replay.

Deadline accounting uses one 25 ms timer, rescheduled only after consumption.
Busy delivery closes the epoch instead of suspending the owner or retrying.
Retirement needs native terminal proof, its acknowledgement and actual helper
exit; missing proof or Manager loss leaves the shared lifetime unclean.
Supervisor shutdown without those proofs also leaves it unclean.

Startup uses `attach-session -E` to preserve the borrowed session environment.
Attachment still changes client counts and session activity. After reading
the server PID and Linux process identity, a fresh same-connection challenge
must return the exact nonce/PID and receive a complete native write
acknowledgement before activation. It shares the original startup deadline.
The server and inspected `/proc` must share a PID namespace.

This requires host authority for completed, clean configuration throughout
the epoch: no aliases overriding admitted command names, no executable
effective hooks, and no unqualified messages or subscriptions that can write
to the control stream. Other clients can inject multiline text through
client-directed messages; parser limits cannot authenticate such output.
Absence of a configuration-error notification cannot certify configuration.
The library never silently disables hooks or changes configuration.

Guardian and bootstrap qualification does not pass connection-wide admission,
retained outcomes, reconnect, FIFO or authoritative subscription behavior.
Those need the Manager/router integration and its fault contracts.
