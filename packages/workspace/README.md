# libtmux workspace for Elixir

This package will provide the versioned JSON workspace loader, planner,
apply journal and CLI. It is under implementation and has no loader or
executable yet.

The package consumes the core `libtmux` package. Published metadata uses
its version requirement. `LIBTMUX_SOURCE_DEPS=1` explicitly selects local
core development wiring; it is not installed-consumer evidence.
