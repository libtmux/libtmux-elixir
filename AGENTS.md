# Agent instructions

This is the bootstrap for libtmux in Elixir. Read [mix.exs](mix.exs) and the
current tree before editing. The scaffold has no tmux implementation or
test suite; add them only when the task authorizes implementation.

## Which policy applies

- Setup, checks, and pull requests:
  [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Documentation, user-facing text, comments, and commits:
  [.github/WRITING.md](.github/WRITING.md).
- Planned contracts and package boundaries: [docs/design.md](docs/design.md).

Each guide is the single home for its subject. `CLAUDE.md` links here.

## Change discipline

- Check the branch and working tree. Preserve unrelated changes.
- Use `rg`, `ag`, or `fd` for searches and `jq` for JSON.
- Reuse existing helpers before adding abstractions. Follow native Elixir
  conventions; sibling ports supply behavioral references, not syntax.
- Keep core runtime dependencies at zero. Workspace and MCP packages depend
  on the core; the core must not depend on them.
- Keep observed values immutable and I/O explicit. Distinguish command
  acknowledgement, operation completion, and cancellation certainty.
- Run the relevant checks and report their scope, whole-command duration,
  and failures or skips. A passing subset does not establish support.

## Shared resources

Future tmux tests and probes must use unique, owned sockets and temporary
directories, with inherited `TMUX` and `TMUX_PANE` cleared. Never use or
stop the default server. Clean up only resources owned by the run and
verify that owned processes exit.
