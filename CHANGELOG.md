# Changelog

## Unreleased

### Added

- Create named detached sessions and windows on an existing server with
  `Server.new_session/3` and `Session.new_window/4`. These one-shot actions
  return the created ID; capture again for a bound reference. (#37)

### Changed

- `Session.windows/2`, `Session.panes/2` and `Window.panes/2` now return
  selections for filtering and checked cardinality. Use `Enum.to_list/1`
  when a list is needed. (#36)

### Fixed

- Scalar predicates returned by `LibTmux.Filter.to_predicate/2` now raise a
  coverage error for missing referenced fields before Boolean evaluation.
  (#35)

## libtmux 0.0.1-alpha.4 (2026-10-25)

### Added

- Inspect control-connection failures with `LibTmux.Control.status/1`,
  including the close reason and captured stderr. (#23)

### Changed

- Nonbang domain actions now report success only for completed commands.
  Match failures as errors; their execution evidence remains available. (#23)
- Send up to 995 literal bytes through either transport. This fixes one-shot
  input above 246 bytes and replaces the documented 1,020-byte limit. (#23)
- Capture full snapshots with fewer tmux processes. Tight byte and command
  budgets may need adjustment. (#23)

### Fixed

- Reject oversized one-shot action requests before contacting tmux and
  return validation errors callers can inspect. (#23)
- Reject inconsistent inputs to `LibTmux.Filter.to_predicate/2` when the
  filter uses relationships. Prepare against each new snapshot or use
  `LibTmux.Selection.where/2`. (#28)

### Documentation

- Follow an executable application-supervision recipe for replacement
  connections and recovery after failure. (#23)

### Development

- Retry transient HexDocs availability failures after successful package
  publication, before checking an installed consumer. (#23)
- Detect stale schema reference pages and exercise packaged supervision
  examples in CI. (#23)

## libtmux 0.0.1-alpha.3 (2026-10-24)

### Documentation

- Follow README examples for capture, filtering, window renaming and pane
  input, with explicit aliases and links to the published API reference.
  Keep fixture setup and cleanup outside the task snippets. (#14)

### Development

- Check README, filtering and API-reference examples in CI, including real
  tmux execution, packaged consumers and owned-process cleanup. Detect drift
  between displayed snippets and their executable sources. (#14)

## libtmux 0.0.1-alpha.2 (2026-10-24)

### Added

- Execute routine commands with `LibTmux.Control.execute/3` without manually
  reclaiming completed operations. `LibTmux.Control.with_connection/2` owns
  connection setup and cleanup around a callback. (#9)
- Split panes, rename sessions and windows, send text or named keys, and
  capture pane contents through domain functions. (#9)
- Build references from captured observations with
  `LibTmux.Ref.from_observation/1`. Qualified-control splits return the
  created pane ID and a bound reference for follow-up actions. (#11)
- Traverse captured session windows and panes with named helpers in
  `LibTmux.Session` and `LibTmux.Window`, without contacting tmux. (#11)

### Changed

- Capture larger servers with fewer tmux commands and query relationships
  without repeatedly validating the captured graph. Direct relationship
  lookups report ambiguity only for the requested objects. (#9)
- Choose split command intent explicitly: session defaults, an empty pane,
  shell text or an argument vector. Argument vectors keep their meaning
  when arguments are added or removed. (#11)
- Get completed values directly from domain bang actions. Unsuccessful
  outcomes raise `LibTmux.Action.CompletionError` with the original evidence;
  ordinary actions retain outcomes for inspection. (#11)
- Report invalid action inputs with their paths and accepted forms, without
  retaining rejected values in diagnostic details. (#11)

### Fixed

- Preserve `nil` when tmux reports an absent pane PID. (#11)
- Reject malformed external filter arrays within the configured limits. (#11)

### Documentation

- Follow separate guides for capture, one-shot actions, managed control and
  retained operations, with executable examples for each workflow. (#9)
- Add `examples/quickstart.exs`, a script that starts a private tmux
  server, captures it and prints its window and pane counts. (#7)
- Document `t:LibTmux.Snapshot.indexes/0` as an opaque type. The
  `t:LibTmux.Snapshot.t/0` reference now links it instead of printing the name
  as plain text. (#8)
- Handle uncertain execution and cleanup failures with a complete recovery
  example; use focused reference examples for cardinality and relationships. (#11)

### Development

- Include this changelog in the Hex package and ExDoc reference. (#9)
- Fail `scripts/check_public_contracts.exs` and `mix test` when a public type,
  spec or callback names a private type, which the generated reference cannot
  link. (#8)

## libtmux 0.0.1-alpha.1 (2026-10-21)

### Added

- Capture sessions, windows, panes, clients and linked-window membership as
  immutable snapshots. Reuse observations without further tmux commands. (#2)
- Select captured objects with `Enum`, native predicates, checked cardinality
  and relationship filters. Share portable filters through versioned JSON. (#2)
- Run Linux one-shot commands with deadlines, output limits and partial-output
  errors. Metadata reads do not attach a client or create a session. (#2)
- Open experimental control connections to existing sessions. Submit requests,
  await retained operation results and reconnect explicitly without replaying
  mutations. (#2)

### Documentation

- Add an ExDoc API reference, public type documentation and field and
  relationship guides. A complete example captures panes, selects them locally
  and reads through one-shot and control connections. (#2)

### Development

- Build the Linux I/O helper through Mix with a C11 compiler. The core has no
  third-party runtime dependencies or NIF. (#2)
- Check tmux 3.3, 3.3a, 3.4 and 3.8 in Linux CI and exercise the packed core
  outside the checkout. (#2)
- Publish the core package and ExDoc documentation to Hex from matching version
  tags after the required Linux checks pass. (#2)
