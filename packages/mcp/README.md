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

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/elixir/)

</div>

This package will provide the bounded STDIO adapter, discovery, retained
operations and host-authorized tmux tools. It is under implementation and
has no protocol server or executable yet.

The package consumes `libtmux` and `libtmux_workspace`, sharing workspace
validation and planning. Published metadata uses version requirements.
`LIBTMUX_SOURCE_DEPS=1` explicitly selects local development wiring; it is
not installed-consumer or protocol evidence.
