<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-512.png" width="128" height="128" alt="libtmux MCP for Elixir">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux MCP for Elixir

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/elixir/latest/mcp/)

</div>

This package will provide the bounded STDIO adapter, discovery, retained
operations and host-authorized tmux tools. It is under implementation and
has no protocol server or executable yet.

Socket selection will follow the core's rule from the first release. The
server passes tmux neither `-L` nor `-S` unless a tool argument or startup
option names a socket, or `LIBTMUX_SOCKET_PATH` (`-S`) or `LIBTMUX_SOCKET`
(`-L`) is set. An explicit argument wins over both variables, and the path
variable wins over the name variable. No dedicated socket of the package's
own is planned. See
[the design note](../../docs/design.md#package-and-validation-boundaries).

The package consumes `libtmux` and `libtmux_workspace`, sharing workspace
validation and planning. Published metadata uses version requirements.
`LIBTMUX_SOURCE_DEPS=1` explicitly selects local development wiring; it is
not installed-consumer or protocol evidence.

Changes to this package are listed in its [changelog](CHANGELOG.md).
