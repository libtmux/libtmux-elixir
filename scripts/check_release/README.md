# check_release

Refuses a release whose package is not the public `libtmux` core, whose
version is a development version or does not match the tag, or whose
changelog is missing, opens with another package's name, has no
`## Unreleased` heading outside a code fence, or is not shipped by the `files`
list of `mix.exs`.

The `publish` job of `release.yml` runs it before it publishes, and
`scaffold.yml` runs it for a version tag. Run it from the repository root with
the tag, such as `v0.1.1`:

```console
$ elixir scripts/check_release/check_release.exs v0.1.1
```

It prints the package name and version as JSON and, under GitHub Actions,
writes `version=` to `GITHUB_OUTPUT`.

## Tests

`tests/check_release_test.exs` breaks a copy of the tree one rule at a time and
requires the check to name the break:

```console
$ elixir scripts/check_release/tests/check_release_test.exs
```
