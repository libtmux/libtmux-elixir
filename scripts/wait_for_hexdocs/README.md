# wait_for_hexdocs

Waits for a published HexDocs page to answer 200. Run it after Hex approval
before checking an isolated install of the published package.

```console
$ elixir scripts/wait_for_hexdocs/wait_for_hexdocs.exs \
    https://hexdocs.pm/libtmux/0.1.1/ \
    60
```

The second argument is the whole budget in seconds, 1 to 120, and defaults to
60. Each request is limited to five seconds or what is left of the budget. It
retries one second later after a 404, 408, 429 or 5xx status, a timeout and a
refused or dropped connection. Any other status, such as a 403, fails at once.
The exit status is 0 when the page answers 200.

## Tests

`tests/wait_for_hexdocs_test.exs` answers each case from a local listener,
including a response that promises a byte it never sends:

```console
$ elixir scripts/wait_for_hexdocs/tests/wait_for_hexdocs_test.exs
```
