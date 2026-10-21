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

</div>

This package will provide the versioned JSON workspace loader, planner,
apply journal and CLI. It is under implementation and has no loader or
executable yet.

The package consumes the core `libtmux` package. Published metadata uses
its version requirement. `LIBTMUX_SOURCE_DEPS=1` explicitly selects local
core development wiring; it is not installed-consumer evidence.
