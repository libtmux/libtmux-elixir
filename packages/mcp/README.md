# libtmux MCP for Elixir

<img src="assets/logo.svg" width="128" height="128" alt="libtmux MCP for Elixir">

This package will provide the bounded STDIO adapter, discovery, retained
operations and host-authorized tmux tools. It is under implementation and
has no protocol server or executable yet.

The package consumes `libtmux` and `libtmux_workspace`, sharing workspace
validation and planning. Published metadata uses version requirements.
`LIBTMUX_SOURCE_DEPS=1` explicitly selects local development wiring; it is
not installed-consumer or protocol evidence.
