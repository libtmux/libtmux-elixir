[version] = System.argv()
Version.parse!(version)

root =
  Path.join(
    System.tmp_dir!(),
    "libtmux-hex-install-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
  )

File.mkdir!(root)

try do
  System.put_env("MIX_INSTALL_DIR", root)
  Mix.install([{:libtmux, "== " <> version}], force: true)

  ^version = Application.spec(:libtmux, :vsn) |> to_string()
  installed = :code.which(LibTmux.Ref) |> to_string() |> Path.expand()
  true = String.starts_with?(installed, Path.expand(root) <> "/")

  {:ok, pane} = LibTmux.Ref.new(:pane, "%7", "hex-install")
  :ok = LibTmux.Ref.validate(pane, "hex-install")

  {:ok, %{stdout: "hex core\n", exit_status: 0, cleanup: :retired}} =
    LibTmux.Transport.OneShot.run("/bin/echo", ["hex core"], max_total_bytes: 9)

  IO.puts("PASS: Hex libtmux #{version} imported and executed outside the checkout")
after
  File.rm_rf!(root)
end
