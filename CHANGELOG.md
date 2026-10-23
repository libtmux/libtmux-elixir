# Changelog

## Unreleased

### Documentation

- Add `examples/quickstart.exs`, a script that starts a private tmux
  server, captures it and prints its window and pane counts. (#7)
- Document `LibTmux.Snapshot.indexes/0` as an opaque type. The
  `LibTmux.Snapshot.t/0` reference now links it instead of printing the name
  as plain text. (#8)

### Development

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
