# Elixir artwork

The library uses the tiled libtmux logo with its cog. The workspace package
uses the same tiles without an overlay, and the MCP package uses the MCP
symbol. Elixir's primary tile is `#8847B9`, from the pinned
[GitHub Linguist palette](https://github.com/github-linguist/linguist/blob/538da05f034fa5c83bd81df128d144e208898da3/lib/linguist/languages.yml).
The lighter upper tile and darker lower tile follow the libtmux family's
OKLab shade adjustments. The source geometry is unchanged.

| Package | Artwork | Local directory |
| --- | --- | --- |
| `libtmux` | Cog | [`assets/`](assets/) |
| `libtmux_workspace` | Plain tiles | [`packages/workspace/assets/`](../packages/workspace/assets/) |
| `libtmux_mcp` | MCP overlay | [`packages/mcp/assets/`](../packages/mcp/assets/) |

Each directory contains an SVG, transparent 32px and 512px PNGs, a favicon,
and light/dark Apple touch, Open Graph and Twitter images. Package READMEs
use their local SVG, and each package's file list includes its own artwork.
The adapters remain under implementation; artwork does not establish an
available CLI or MCP server.

## Sources and updates

The vendored files come from the private `libtmux/assets` repository.
Each artwork directory includes a `source.json` with its revision and
SHA-256 digests; the core's record is [`assets/source.json`](assets/source.json).
The original libtmux and tmuxp paths were
supplied by the project owner. The MCP overlay uses the symbol from its
[upstream artwork](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/088176704a4e8f20e7f1d237de1de8484aa412fd/docs/logo/light.svg).

Regenerate artwork in the asset kit, then copy the selected exports here
and update the source record. The kit also owns the two flat pane styles,
the CSS-controlled SVG, the Astro component, and the full browser/mobile
exports. Keep those generators in the kit.

## Documentation and previews

Use `logo.svg` for a documentation logo and `favicon.ico` for its favicon.
ExDoc is not configured in this package yet; its eventual configuration can
use those local files. Crawler metadata needs absolute public URLs to the
1200 × 630 `opengraph-light.png` and 1200 × 600 `twitter-light.png` images.
The private source repository is not an image host for previews.

The shared docs repository vendors the full Elixir library, workspace and
MCP sets under `site/public/brand/elixir/`. It owns browser manifests and
page metadata when Elixir documentation is integrated.
