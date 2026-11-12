# Elixir artwork

The library uses the tiled libtmux logo with its cog. Elixir's primary tile is `#8847B9`, from the pinned
[GitHub Linguist palette](https://github.com/github-linguist/linguist/blob/538da05f034fa5c83bd81df128d144e208898da3/lib/linguist/languages.yml).
The lighter upper tile and darker lower tile follow the libtmux family's
OKLab shade adjustments. The source geometry is unchanged.

The artwork is in [`assets/`](assets/). The directory contains an SVG,
transparent 32px and 512px PNGs, a favicon, and light/dark Apple touch, Open
Graph and Twitter images.

## Sources and updates

The vendored files come from the private `libtmux/assets` repository.
The artwork directory includes a `source.json` with its revision and
SHA-256 digests: [`assets/source.json`](assets/source.json).
The original libtmux and tmuxp paths were supplied by the project owner.

Regenerate artwork in the asset kit, then copy the selected exports here
and update the source record. The kit also owns the two flat pane styles,
the CSS-controlled SVG, the Astro component, and the full browser/mobile
exports. Keep those generators in the kit.

## Documentation and previews

Use `logo.svg` for a documentation logo and `favicon.ico` for its favicon.
ExDoc uses the local SVG logo and includes the artwork in its output.
Crawler metadata needs absolute public URLs to the
1200 × 630 `opengraph-light.png` and 1200 × 600 `twitter-light.png` images.
The private source repository is not an image host for previews.

The shared docs repository vendors the Elixir library set under
`site/public/brand/elixir/`. It owns browser manifests and
page metadata when Elixir documentation is integrated.
