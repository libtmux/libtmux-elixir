# Command and field encoding

`LibTmux.Command` is a value. Constructing it or rendering its bytes performs
no I/O. The one-shot and control transports remain under implementation.

## Separate parsers

`Command.argv/2` returns process arguments and protects terminal semicolons
from tmux's argument-vector parser. It does not invoke a shell.
`Command.render/2` produces one tmux command line with every argument byte
octal-escaped inside double quotes. The result contains no raw newline or
carriage return. It excludes the framing newline a future writer must add.
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
The conservative format performs several substitutions; it makes no
zero-copy or optimized multi-field claim.

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
