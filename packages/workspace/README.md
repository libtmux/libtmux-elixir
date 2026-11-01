<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-512.png" width="128" height="128" alt="libtmux workspace for Elixir">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux workspace for Elixir

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/elixir/latest/workspace/)

</div>

This package will provide the versioned JSON workspace loader, planner,
apply journal and CLI. It is under implementation and has no loader or
executable yet.

Socket selection will follow the core's rule from the first release. The
loader and CLI pass tmux neither `-L` nor `-S` unless the user gives a socket
option or sets `LIBTMUX_SOCKET_PATH` (`-S`) or `LIBTMUX_SOCKET` (`-L`). An
explicit option wins over both variables, and the path variable wins over the
name variable. No default socket of the package's own is planned. See
[the design note](../../docs/design.md#package-and-validation-boundaries).

The package consumes the core `libtmux` package. Published metadata uses
its version requirement. `LIBTMUX_SOURCE_DEPS=1` explicitly selects local
core development wiring; it is not installed-consumer evidence.

Changes to this package are listed in its [changelog](CHANGELOG.md).
