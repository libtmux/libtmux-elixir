# check_docs_links

Checks every local file and HTML fragment that the pages of a rendered ExDoc
site link to, without network requests. It reads `href`, `src` and `srcset`
values, skips anything with a scheme or a host, and reports a missing file or a
missing `id` or `name` fragment. ExDoc's optional `docs_config.js` version
catalogue is counted, not required. It does not verify external sites.

`scaffold.yml` and the `publish` job of `release.yml` run it after
`mix docs`. It installs the HTML parser [Floki](https://hex.pm/packages/floki)
with `Mix.install/2` on first use:

```console
$ elixir scripts/check_docs_links/check_docs_links.exs doc
```

The directory defaults to `doc`. The exit status is 1 when a link is broken.

## Tests

`tests/check_docs_links_test.exs` builds small sites that must pass and sites
that must fail:

```console
$ elixir scripts/check_docs_links/tests/check_docs_links_test.exs
```
