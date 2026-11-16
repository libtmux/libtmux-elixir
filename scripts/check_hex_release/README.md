# check_hex_release

Checks a published Hex release. After `mix hex.publish`, the `publish` job of
`release.yml` runs it on the Hex API page of the release before it waits for
the documentation.

The page must answer 200 with JSON that names the release version and declares
no requirement, because the core has no runtime dependency. The script makes
one request of at most 30 seconds and exits 0 when the release matches and 1
otherwise.

```console
$ elixir scripts/check_hex_release/check_hex_release.exs \
    https://hex.pm/api/packages/libtmux/releases/0.1.1 \
    0.1.1
```

## Tests

`tests/check_hex_release_test.exs` answers each case from a local listener: a
matching release, a release of another version, one with a requirement, a
status other than 200, a document that is not JSON and a refused connection.

```console
$ elixir scripts/check_hex_release/tests/check_hex_release_test.exs
```
