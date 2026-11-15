# check_example_docs

Keeps each program shown in `README.md` and `docs/*.md` equal to the executable
example it comes from. A block marked
`<!-- example: examples/NAME.exs -->` must hold the whole file. A block marked
`examples/NAME.exs#REGION` must hold the lines between `# docs:begin REGION`
and `# docs:end REGION`, with their common indentation removed. Every file in
`examples/` must be shown somewhere.

`scaffold.yml` runs it, and the packed example check runs the sources. Run it
from the repository root; `--write` rewrites the displayed copies:

```console
$ elixir scripts/check_example_docs/check_example_docs.exs
```

## Tests

`tests/check_example_docs_test.exs` drifts a small repository each way the
check must notice:

```console
$ elixir scripts/check_example_docs/tests/check_example_docs_test.exs
```
