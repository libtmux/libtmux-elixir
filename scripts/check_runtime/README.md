# check_runtime

Checks that the active Elixir and OTP match the profile a job asks for:

- `reference`: the exact pair in
  [`priv/tmux/support.json`](../../priv/tmux/support.json)
- `tracking`: any release that satisfies `.tool-versions` and the supported
  minimum
- `custom`: the identity only. A dispatch that names its own versions is
  debugging outside the supported pairs, so nothing is asserted.

Every native cell of `scaffold.yml` and the `publish` job of `release.yml` run
it. Run it from the repository root:

```console
$ elixir scripts/check_runtime/check_runtime.exs tracking
```

It prints `{"profile", "elixir", "otp", "compiled_otp"}` as JSON.

## Tests

```console
$ elixir scripts/check_runtime/tests/check_runtime_test.exs
```
