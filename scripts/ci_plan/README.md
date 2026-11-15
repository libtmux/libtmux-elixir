# ci_plan

Plans the native tmux cells of a CI run from
[`priv/tmux/support.json`](../../priv/tmux/support.json) and the event that
started it, so no workflow lists a tmux version.

The `plan` job of `scaffold.yml` runs it and feeds the matrix to the `native`
job. Each cell names a tmux release, tag, branch or commit; the shared
`build-tmux` action builds it. To try a plan locally:

```console
$ elixir scripts/ci_plan/ci_plan.exs plan --event push
```

Scopes:

- `edges`: the oldest and newest required release, plus the tracking toolchain
  on the newest. The default for a push, a pull request and a dispatch.
- `full`: every required release. A release, a schedule and a dispatch that
  asks.
- `custom`: the refs a dispatch names, on the reference toolchain or on the
  Elixir and OTP versions it names.

`--tmate` gives exactly one cell of a dispatch a debugging session. The plan
refuses a list of refs without `custom`, an unusable ref or version, more than
12 custom cells and a session on more than one cell.

## Tests

`tests/` holds the planner tests and two checks that the workflows and the
documents follow the plan:

```console
$ elixir scripts/ci_plan/tests/ci_plan_test.exs
```

```console
$ elixir scripts/ci_plan/tests/ci_workflow_test.exs
```

```console
$ elixir scripts/ci_plan/tests/ci_docs_test.exs
```
