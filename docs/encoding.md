# Command and field encoding

`LibTmux.Command` is a value. Constructing it or rendering its bytes performs
no I/O. Both one-shot execution and the qualified persistent control lane
use these encoders.

## Separate parsers

`Command.argv/2` returns process arguments and protects terminal semicolons
from tmux's argument-vector parser. It does not invoke a shell.
`Command.render/2` produces one tmux command line with every argument byte
octal-escaped inside double quotes. The result contains no raw newline or
carriage return. It excludes the framing newline the control writer adds.
Both renderers validate the encoded byte budget before dispatch.

Command quoting does not protect a value that a command interprets as a
tmux format. `LibTmux.Format.literal/1` constructs a literal format operand
without evaluating embedded `#{...}`, shell jobs or shorthand variables.
It accepts non-NUL bytes. The command still needs its own appropriate
format flags; arbitrary commands have different expansion behavior.

## One field per response

`Format.field/1` encodes a named field with a `v1:` marker. It replaces
backslashes first, then dollars and ASCII control bytes, using fixed tmux
substitutions. `LibTmux.Codec.decode_field/3` with `encoding: :escaped_v1`
requires that marker, removes one framing newline and decodes escapes once.
The conservative field format performs several substitutions.

This encoding avoids an ambiguity in tmux 3.4: its command print path
escapes some bytes while preserving literal backslashes. Removing arbitrary
backslashes from that output would corrupt legitimate values. A versioned
field encoding protects those values before printing. A separator byte
alone cannot do that, because titles and paths may contain it.

The default raw decoder removes only the final framing newline. Its source
must independently guarantee unmodified bytes. It must not be applied to
an unqualified tmux print path. Text decoding requires UTF-8; `:bytes`
retains arbitrary bytes. Integer parsing consumes the whole value and can
enforce a range; Boolean parsing accepts only `0` or `1`.

## Capture rows

Snapshot capture batches each physical entity's free-form fields in one
response. A row starts with `r1:N`, followed by N tab-separated `v1:` fields
and one final newline. Each field uses the same conservative encoder above:
tabs and newlines inside values become escapes, so they cannot become row
delimiters. The decoder requires the expected version and field count,
rejects malformed or truncated data, then validates each decoded field
against its schema. Invalid UTF-8 remains an error for text fields.

The response ceiling applies to the complete encoded row, including markers
and separators. Multiple fields that each fit the ceiling individually can
exceed it together; capture returns a resource-limit error, with no partial
graph or alternate decoder. The default ceiling remains 64 KiB per response.

One successful attempt uses `10 + S + W + P` commands, where S, W and P are
the physical session, window and pane counts. Each command still launches
one owned helper and one tmux client. Linked windows share their text read.
The two topology scans, incarnation checks, contextual-row accounting and
capture-wide deadline and byte budgets remain in force. This encoding does
not qualify arbitrary pane output or hook output for a shared control lane.

## Bounded framing

`LibTmux.Protocol` is a pure control-mode parser with separate chunk, line,
frame, line-count and emitted-event ceilings. It retains reply guard IDs;
notification-looking lines inside a reply remain output. A rejected suffix
preserves completed prefix events in the structured error. Retire a lane
after a parse error.

Lexical parsing cannot authenticate output that forges a matching guard.
Commands, aliases, hooks and subscriptions require separate admission
rules before sharing a persistent lane. Parser ceilings also do not bound
upstream Port delivery or a connection owner's mailbox. Those transport
contracts require independent qualification.
