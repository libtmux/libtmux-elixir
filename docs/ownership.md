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

Reserved closure revokes the exact lifetime generation without consuming a
command or metadata slot. Guardian observes that word on its accounting
timer even when Manager or Router makes no progress. A concurrent
starting-to-ready transition cannot escape revocation; retries follow only
the same generation. Revocation requests closure and blocks later checks.
It does not prove cleanup or prevent a write that already passed its final
check. Native and actor retirement remain separate required evidence.

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

The internal epoch router registers operation identity and FIFO position
before sending fragments. A qualified reply after final-fragment dispatch
can establish an immutable logical result before the native acknowledgement
arrives. The writer still waits for native acknowledgement before advancing;
wire retirement also requires it. Completed reply events survive a later
parser error in the same chunk. Expired unsent work removes its exact queued
token before capacity reuse. A retained reply observation and its logical
result are separate copies in the eventual connection byte accounting.

The initial lane admits encoded field reads and literal server user-option
writes, with bounded ASCII option names and no value expansion. It rejects
arbitrary command lines. Literal send-keys still needs domain qualification:
pane-mode key bindings can enqueue additional commands even with `-l`.
Reply numbers must increase when observed; gaps are normal because other
clients and callbacks use the same server counter. This does not detect
every possible counter wrap or authenticate an unqualified stream.

Metadata requests use a separate fixed ETS inbox before any wake message.
Its context binds the real table owner, capacity, allowed request kinds and
atomics references. Publication creates the caller's reply alias and token;
only a small ready notification enters its mailbox. Owner completion and
caller receipt remain separate: a finished row stays occupied until alias
closure and receipt acknowledgement, or caller death. A monotone receipt
word cannot regress when a delayed old close meets a replacement generation.
Wake hints also coalesce across slot reuse; accounting sweeps never clear a
hint that a paused publisher still owns.

Inbox ceilings cover fixed metadata rows and serialized result size. They
do not establish a bound on all retained BEAM binaries: a small subbinary can
retain a larger parent. Integrated operation waiters must retain bounded
record references and include result storage in connection-wide accounting.

The retained-record registry finalizes an epoch only after its exact Router
PID has exited. It scans current admission leases, including a consumed
lease whose Router died before storing its first record. Router stores its
record and writing phase before sending, so an absent matching record proves
no write under that ordering. Existing acknowledged results remain intact;
dispatched work without evidence remains unknown. These outcomes retain
their slots until explicit release. Clearing a released record uses its
exact old value, preserving any replacement already published in that slot.
Logical finalization does not prove Guardian/helper cleanup or authorize a
new epoch; Manager must separately establish complete resource retirement.

Startup registration uses one fixed row for three epoch actor roles and its gate.
Each actor records its own PID before side effects. Closing the gate captures
all accepted PIDs in the same CAS; a queued late startup cannot be omitted
between a separate read and close. Router and Guardian bind the supplied
registration to their manager, epoch and original deadline. Guardian also
rechecks actor aliveness and its starting lifetime before opening the driver.
An accepted PID remains owned through actual exit: registration or a pre-open
check can race later closure. Gate closure alone is not native retirement.

Manager keeps one asynchronous request to an ordinary Supervisor outstanding
while it accounts for deadlines and metadata. A suspended Supervisor cannot
park that accounting. Closing the reply alias does not cancel a queued
Supervisor action; an abandoned unresolved start leaves cleanup unknown and
blocks replacement. Captured actors remain monitored independently of the
request alias. A Router born without a Guardian exits after the startup gate
closes. A captured pair binds even during closure, including buffered native
retirement events.

Explicit reconnect carries its original deadline through old retirement and
new bootstrap. Replacement requires native proof, actual Guardian and Router
exit, the host's child-finalization acknowledgment and EpochSupervisor exit.
Manager restarts preserve the external lifetime latch and do not reconnect
automatically. The internal qualified cases retain outcomes across reconnect,
forget exact completed leases, and expire retained records. Accepted metadata
work remains owned after caller timeout or alias closure; neither cancels it.

The internal connection Supervisor owns the view and starts EpochHost before
Manager. Its external child-spec factory pins the lifetime across root
restarts. Manager replacement invalidates its old tables; root replacement
also invalidates the view. A surviving view never recovers old operation
evidence. Finite Supervisor shutdown can leave descendants alive; only the
shared unknown/unretired lifetime prevents a replacement helper in that case.
An unsuccessful descriptor handoff after root startup kills the known root
and reports cleanup uncertainty, even after observing root exit.

Public bounded connection startup, retained outcome APIs, waiter pinning,
connection-wide accounting and authoritative subscriptions remain under
implementation. These component checks do not qualify those contracts.
