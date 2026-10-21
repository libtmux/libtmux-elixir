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
buffers and bounded initialization allocations. It requests 8 KiB child
pipes and a 4 KiB signal pipe. Kernel page rounding can increase the actual
capacities; a resize failure rejects startup. Parent pipes and Port delivery add
buffers outside the capture byte count. Aggregate accounting must measure
actual pipe capacities. See [the protocol](../c_src/README.md).

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
router independently. Startup grants one stdout credit after router demand.
After activation it keeps one native read in flight and buffers at most
64 KiB or 128 stdout chunks while Router consumes its previous chunk. Each
native read and delivered chunk fits 8 KiB. Exceeding either queue ceiling
closes the epoch with `resource_limit`; it does not indefinitely stop reading
from a still-attached client. These limits do not cap the borrowed tmux
server's allocations or total process memory.

Guardian caps stderr at 8 KiB and 64 chunks, and acknowledges one write
fragment at a time. A fragment fits 8 KiB; a complete rendered command fits
64 KiB. The writer rechecks the consumed publication lease, original deadline
and epoch. A partial line keeps its writer until the newline is acknowledged
or the epoch closes. Completed slots retain their generation to reject replay.

After orderly EOF or native exit, Guardian blocks further writes and drains
already-received stdout through the existing Router credits. An end token
follows pending native write acknowledgements; Router acknowledges it after
processing earlier data and write messages. Only then does ordinary closure
finalize remaining operations. Explicit closure, owner loss or protocol failure
can abort that drain. Established results survive; unfinished effects remain
uncertain. Drain and closure share the original 750 ms Guardian and 800 ms
Manager cleanup allowances. Neither clock restarts after data delivery.
Helper terminal acknowledgement remains independent of Router progress.

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

Inbox outcomes copy every binary leaf, including map keys. Copying charges
bytes and nodes before allocation, caps depth at64 and nodes at8192, and
rejects functions, ports and unqualified references. Known context references
come from explicitly identified, separately bounded resources. Metadata keeps
the default64 KiB outcome allowance; an independently configured Inbox may
reserve1–128 KiB so a64 KiB reply plus its envelope fits. The1 KiB minimum
covers fixed fallback errors. Copying shares the original deadline, checked
again before result publication. These limits do
not yet establish complete connection-wide heap/work accounting.

The selected waiter design retains bounded outcome copies in receipt-controlled
Inbox rows, superseding the earlier record-reference-only proposal. This avoids
cross-table pin/reclamation races at the cost of separately charged copies.
The internal waiter owner settles accepted requests from the exact immutable
terminal record before releasing it. A prior pending read cannot justify
forgetting a later completed record. Closed or expired waiters affect no
operation state; pre-acceptance await failures retain unknown effect certainty.
Manager services its separate waiter Inbox before reconnect admission and
startup continuations, and again after actor events. Both explicit forget
and automatic record expiry use the exact-record release barrier. A finished
waiter copy survives record reclamation and epoch replacement until receipt.
Lost waiter storage closes an active epoch and blocks this Manager's reuse.
If native retirement was already proved, that lifetime remains retired;
the Manager's fault does not erase cleanup knowledge or preserve lost tables
across its replacement.

Accounting finalizes retained records for all observed dead destinations in
one lease scan, matching each epoch and PID together. It preserves acknowledged
results and dispatched uncertainty, and releases no live destination's record.

`LibTmux.Operation` pins its original record, lease and Inboxes. Retained
status and result reads are local. Each await claims a bounded independent
slot and releases its exact alias and monitor on return; timeout does not
stop the operation. Metadata admission errors cannot label existing effects
as unwritten. Canonical failed, skipped and unknown outcomes remain values,
including in bang functions. Forget uses the original lease epoch after
reconnect. Stop validates the authoritative Births owner, epoch and Router
before revoking its generation through reserved capacity; an already-retired
record needs no surviving Births table. Stop closes the whole epoch and may
affect siblings. It is a request, never rollback or native retirement proof.

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

The internal startup adapter passes the remaining initialization budget to
OTP's generic server entry with its source-qualified Supervisor init shape.
OTP stores the adapter as its callback; the adapter delegates the original
module and arguments. A private alias captures the exact Root PID before
delegation so cleanup drains only that Root's racing startup ACK or NACK.
Descriptor publication rechecks the original deadline, and failed handoff
cleanup uses only its remaining budget. OTP still waits for actual Root DOWN
after an initialization timeout; this primitive alone does not prove a strict
caller-return deadline or complete descendant retirement.

Both startup wrappers close their private reply aliases through local BIFs
and zero-time receives. Timeout cleanup does not demand-load the shared reply
helper after Root exit. Isolated loader-gate checks qualify this dependency;
they do not bound OTP's actual-DOWN wait or explain earlier timing failures.

Failed initial startup fences the fresh lifetime even before its first epoch
reservation. If that reservation wins the CAS race, the fence closes only the
first generation. Proven retirement remains intact, and later generations
cannot be revoked by an old failure. Root cleanup uses its generation captured
at startup entry. Manager can remain inert at generation zero with unknown
cleanup through normal shutdown or Host loss, without creating epoch actors.
This fence handles observed startup failures; it does not establish recovery
from untrappable caller or VM death. One lifetime belongs to one connection
Root; concurrent starts sharing that lifetime intentionally fail closed.

`Control.start_link/1` requires an explicit Server, exact existing session ID
and host-qualified lane. It returns `{:ok, root, control}` only after fresh
bootstrap and a bounded ready exchange. Its 1..600000ms timeout includes
preparation, Root startup and handoff; every successful handoff rechecks the
original deadline. The provisional handle stays internal. Accepted ready
replies bind their exact endpoint without a later Births or latest-view lookup.
If startup failed before ready registration, the error retains the original
failure kind. Cleanup fences the lifetime, requests exact-Root termination,
and reports actual Root exit only when observed. Native cleanup can remain
unknown. Ordinary linked-process exits retain their OTP semantics.

`Control.child_spec/1` prepares detached bounded process bytes without I/O.
One lifetime survives its permanent factory's invocations. Each invocation
starts a new startup budget, but a nonfresh lifetime returns inert instead of
automatically attaching. Explicit reconnect requires proven retirement;
unknown cleanup, including generation zero, returns a structured error.
`Supervisor.start_child/2` and `Supervisor.restart_child/2` return fresh handle
info. After automatic restart, terminate and restart that exact child to obtain
the new info; this recovery does not clear unknown cleanup. Retain a distinct
child spec/lifetime per Root, and never use an old handle as a locator.

`Control.submit/3` pins a ready Root view, Manager and epoch. It detaches the
request's binary leaves under a separate 20,000-byte owned-term limit before
claiming a fixed operation slot. One deadline includes validation, admission,
queueing, writing and replies. After claim, pure Operation binding preserves
the handle even if context disappears. A final local gate check can suppress
publication; the reserved lease stays owned. Its original deadline requests
epoch closure; capacity still follows native/destination retirement and
record retention or explicit forget rules. Router and Guardian independently
validate before writing.

`Control.request_close/1` requests whole-epoch closure without claiming a
slot, including when operation and metadata capacity are full. It does not
acknowledge native retirement or roll back siblings. Repeated requests for
the same closing or proven-retired generation succeed; old handles cannot
follow replacement Managers or epochs. Status errors report unknown
certainty about existing work; a rejected new, unadmitted submission reports
no write.

`Control.close/2` waits for native and epoch-actor retirement plus the Host's
epoch-child finalization acknowledgement under its original budget. An
admitted metadata watcher retains its fixed Inbox cell
through settlement, including after caller closure. Metadata settlement
failure blocks replacement. Ready watches never start a failed or closed
epoch. Accepted retirement watches settle before reconnect in the same batch,
independent of slot order. Epoch reservation rechecks metadata and waiter
storage; lost storage cannot authorize replacement.

`Control.reconnect/2` returns the acknowledged endpoint directly. A delayed
caller receives that epoch even if a newer one already exists; its handle
then reports stale. It does not reread the latest view or replay operations.
The Root and retained records outlive ordinary epoch closure. Public lifecycle
errors preserve unknown certainty about existing effects; direct retirement
proof must still be observed within the original close budget.

Strict caller-return startup bounds, connection-wide accounting and
authoritative subscriptions remain unqualified. These component checks do
not qualify those contracts.
