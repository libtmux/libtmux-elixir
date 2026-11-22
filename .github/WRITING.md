# Writing

Repository-specific rules for documentation, user-facing text, ExDoc and source
comments, changelogs, and commits in `libtmux-elixir`. Shared organization
voice, CommonMark wrapping, slop prevention, and commit conventions live in
[`libtmux/.github` `WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md);
development workflow and checks live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Terminology and claims

Write `tmux` in lowercase everywhere, including at the start of a sentence, and
use consistent domain nouns (`server`, `session`, `window`, `window_link`,
`pane`, `client`). Describe observable behavior and name handled failures or
reproducible measurements. Planned capabilities remain explicitly planned until
implementation and checks establish them; omit installation or usage examples
for unpublished packages.

## README and guides

Teach the task before the API. Keep API contracts next to their definitions and
conceptual explanations in one guide, linking each instead of duplicating
prose. Preserve relative repository links; change a packaged copy only when an
installed consumer check shows that a target breaks.

### Code blocks

- Use `console` fences with a `$ ` prefix for shell commands.
- Put one paste-and-run command in each block. An explicit `&&`, `;`, or `\`
  chain counts as one command.
- Put prerequisites and explanations outside the fence.
- Split long commands with `\`, using one flag per continuation line.
- Run complete Elixir examples and check their stated results. Keep API
  proposals in design prose or tables until executable examples exist.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** examples use 80 columns, enforced by the
  `check-example-width` action of `libtmux/.github` and
  `.github/example-width.toml`. Mix formats `examples/**/*.exs` at Elixir's
  98-column default, so keep sub-expressions named or piped across lines so
  `mix format` does not rejoin them past 80 columns.
- **Not formatted:** Markdown fences in `README.md`, `docs/*.md`,
  `.github/*.md`, and `scripts/*/README.md` are maintained at 80 columns by
  hand; Elixir `@moduledoc` and `@doc` fences follow the same limit.
- **Runs, compiles, exempt:** `mix test` executes pure doctests, and
  `MIX_ENV=test mix run scripts/check_package.exs --examples` runs every
  `examples/*.exs` program from the built Hex archive on an owned tmux server.
- **Compared output and copied blocks:** JSON output assertions stay intact.
  Edit programs in `examples/`, then refresh `<!-- example: ... -->` excerpts
  in `README.md` and `docs/*.md` with
  `elixir scripts/check_example_docs/check_example_docs.exs --write`;
  `check_example_docs.exs` rejects drift. Prose policy counterexamples below
  demonstrate formatting and are not executable product examples.

Bad, over 80:

```elixir
  result = snapshot |> Snapshot.panes() |> Selection.where(current_command: [in: ["nvim", "vim"]])
```

Good, name the reusable criteria:

```elixir
  editors = [current_command: [in: ["nvim", "vim"]]]
  result = snapshot |> Snapshot.panes() |> Selection.where(editors)
```

## README shape

The README is for scanning. A reader should find the call to use at a glance.

- Header: the logo block, a centered title, then a row of badges for CI, the
  Hex release, libtmux.org docs and the license. Write the whole header in
  HTML. ExDoc's Earmark does not parse Markdown inside an HTML block, so
  Markdown there shows as literal text. Add no badge or link for a registry or
  libtmux.org page that does not return 200; a 302 is fine for a port root.
- Each `##` section is a task in the reader's words, such as finding sessions,
  windows and panes.
- Each `###` heading is an API name linked to its libtmux.org reference page,
  then a colon and its job in plain words.
- Under a heading: a line or two naming linked sibling APIs, the example, what
  it prints, at most one short note and a `More:` link to the guide.
- No paragraph runs past three lines. A list of facts is a bullet list. No
  feature inventory or manual contents bar.
- Requirements are actionable floors, such as "tmux 3.3 or newer"; link
  [implementation notes](../docs/implementation.md#packages-and-support) for
  exact matrix details.
- Never remove an example, command block, index table or guide table to shorten
  the README. Shorten the prose and move detail to a guide.
- Support and status and What it leaves out are short bullets that open with a
  bold lead, followed by contributor links and the
  [libtmux.org](https://libtmux.org/) family line.
- A repository with more than one package lists them under Packages: one
  heading per package linked to its directory, a one-line description, then
  links to its API reference, registry page and changelog.
- Examples start with their imports, wrap their body in `Server.with_owned/2`
  to start and stop a private server through the library rather than the shell,
  and stay synced via `scripts/check_example_docs/check_example_docs.exs`.
- Show the features the port has (queries, filters, and control connections)
  and list planned features (`Query`, `Batch`, `Plan`, `Observation`,
  `Tracker`) under What it leaves out until they exist.

## Elixir API documentation

Write `@moduledoc`, `@doc`, and `@typedoc` beside their definitions. The first
paragraph states the result and stands on its own. Use native ExDoc references
such as `Module.function/arity`, `c:Module.callback/arity`, and
`t:Module.type/arity`; verify rendered links with
`mix docs --warnings-as-errors` and `scripts/check_docs_links/check_docs_links.exs`.

Document the contract a caller needs: accepted inputs, defaults, tagged results
and exceptions, ownership, ordering, deadlines, cancellation, output bounds,
and cleanup. State whether a value is observed data and whether a function
performs I/O. Explain required coverage and the tmux feature floor where they
affect the call.

Use `## Examples` for worked use and doctests for pure examples that can run
without tmux. Add truthful `:since` metadata when a feature ships. Typespecs
document contracts; do not present them as runtime validation. Preserve
tooling directives (`# docs:begin`, `# docs:end`) and protocol or platform
workaround notes in source comments.

## Commits and pull requests

Follow the scoped commit and pull request conventions in
[`libtmux/.github` `WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md#commits-and-pull-requests)
(`scope(type[detail]): concise description`, imperative subject <= 50
characters, `why:` paragraph and `what:` bullets wrapped <= 72 characters, one
topic per commit). Keep temporary validation results in the pull request
description rather than commit prose.

## Release notes

Each changelog bullet names one observable change and links the relevant API or
issue, with migration advice beside the change. Release notes state the upgrade
benefit, compatibility change, and required action; support claims refer to
that release's completed checks.

An entry goes in `CHANGELOG.md`, the changelog of `libtmux`. A change to
documentation, CI or release tooling goes there too.
