# docs_preview_cleanup

Deletes the documentation preview of a closed pull request. The
`docs-preview-cleanup.yml` workflow runs it when a pull request closes, on the
default branch's copy of the script, so no pull request content runs with the
cleanup role.

It has two actions:

- `eligibility` reads the pull request with `gh api`, which needs `GH_TOKEN`,
  and appends `should_cleanup=true` to the file named by `--github-output`
  when the pull request is closed. A closed event can be rerun after the pull
  request reopens, so the workflow reads the state again before it assumes the
  cleanup role. The script writes `should_cleanup=false` first and exits 1 when
  the number is not a positive integer or the response is not the pull request
  asked for, with a state other than open or closed.
- `delete` runs `aws s3 rm` on `s3://<bucket>/en/elixir/pr-<number>/` with
  `--recursive`, after the same number check.

```console
$ elixir scripts/docs_preview_cleanup/docs_preview_cleanup.exs \
    eligibility \
    --repository libtmux/libtmux-elixir \
    --pr 12 \
    --github-output "$(mktemp)"
```

## Tests

`tests/docs_preview_cleanup_test.exs` accepts a closed pull request and an open
one, refuses each malformed response and number, checks the preview prefix, and
runs the command line on a non-numeric number to see it exit 1 before it calls
`gh` or `aws`. The two calls run in CI when a pull request closes.

```console
$ elixir scripts/docs_preview_cleanup/tests/docs_preview_cleanup_test.exs
```
