# Writing

This guide governs documentation, user-facing text, comments, and commit
messages. [CONTRIBUTING.md](CONTRIBUTING.md) owns the development workflow.

## Voice

Lead with the result or the reader's task. Use active voice, present tense,
concrete nouns, and short sentences. Assume no shared conversation history:
explain what a referenced issue or decision means, not just its identifier.

Describe observable behavior. Name the handled failure instead of calling
code robust. Give measurements instead of calling it fast. Remove filler,
marketing claims, emojis, and tool signatures. Planned capabilities remain
explicitly planned until implementation and checks establish them.

## README and guides

Teach the task before the API. Keep the README ordered around purpose,
status and prerequisites, installation, the smallest tested task, defaults
and failure behavior, package boundaries, and contributor links. Omit an
installation or usage example when no usable package exists.

Keep API contracts next to their definitions and conceptual explanations in
one guide. Link to each instead of maintaining duplicate descriptions.
Use tables for comparisons and lists for steps or parallel facts. Preserve
relative repository links; change a packaged copy only when an installed
consumer check demonstrates that a target breaks.

## Markdown and examples

Use CommonMark with blank lines around headings and lists. Wrap repository
prose at about 80 columns, except tables and long links. Do not hard-wrap
GitHub issue or pull request paragraphs. Exclude personal information and
local absolute paths from published text.

Code blocks are paste-and-run units:

- Use `console` fences and a `$ ` prefix for shell commands.
- Put one command in each block. An explicit `&&`, `;`, or `\` chain counts
  as one command.
- Put prerequisites and explanations outside the fence.
- Split long commands with `\`, using one flag per continuation line.
- Run complete Elixir examples and check their stated results. Keep API
  proposals in design prose or tables until executable examples exist.

Examples that touch tmux own their socket and cleanup. When examples become
part of public documentation, extract snippets from checked source files
or add a drift check. A compile-only example does not prove tmux behavior.

## Elixir API documentation

Write `@moduledoc`, `@doc`, and `@typedoc` beside their definitions. The
first paragraph states the result and stands on its own. Use native ExDoc
references such as `Module.function/arity`, `c:Module.callback/arity`, and
`t:Module.type/arity`; verify that rendered links resolve once ExDoc is
configured.

Document the contract a caller needs: accepted inputs, defaults, tagged
results and exceptions, ownership, ordering, deadlines, cancellation, output
bounds, and cleanup. State whether a value is observed data and whether a
function performs I/O. Explain required coverage and the tmux feature floor
where they affect the call.

Use `## Examples` for worked use and doctests for pure examples that can run
without tmux. Add truthful `:since` metadata when a feature ships. Typespecs
document contracts; do not present them as runtime validation.

Source comments explain an invariant, constraint, failure mode, or
non-obvious intent. Prefer one or two lines. Delete comments that narrate
the next expression or repeat names, types, and control flow. Preserve
tooling directives and explanations of protocol or platform workarounds.

## Commits and pull requests

Use `scope(type[detail]) Concise description`. The detail is optional. Use
a lowercase scope unless it names a proper product or class. Follow the
subject with a `why:` paragraph and focused `what:` bullets explaining the
durable reason and changes. Keep each commit about one topic.

Review descriptions lead with the concrete problem and resulting behavior.
Explain the final change for someone who has not read the conversation.
Include relevant verification, failures, and skipped checks in the review;
temporary validation results do not belong in commit prose.

## Future release notes

Once releases exist, each changelog bullet names one observable change and
links the relevant API or issue. Put migration advice beside the change.
Release notes state the upgrade benefit, compatibility change, and required
action. Support claims refer to that release's completed checks. Avoid
feature totals and narratives of internal cleanup.
