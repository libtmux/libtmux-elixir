root =
  Path.join(
    System.tmp_dir!(),
    "libtmux-consumer-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
  )

File.mkdir!(root)

try do
  source_override = System.get_env("LIBTMUX_SOURCE_DEPS")
  System.delete_env("LIBTMUX_SOURCE_DEPS")

  try do
    Enum.reduce(
      [
        {:libtmux_workspace, "workspace", [:libtmux]},
        {:libtmux_mcp, "mcp", [:libtmux, :libtmux_workspace]}
      ],
      %{libtmux: Mix.Project.config()[:version]},
      fn {app, directory, expected}, versions ->
        {dependencies, version} =
          Mix.Project.in_project(app, Path.join("packages", directory), fn _ ->
            config = Mix.Project.config()
            {config[:deps], config[:version]}
          end)

        ^expected =
          Enum.map(dependencies, fn {name, requirement} when is_binary(requirement) -> name end)

        for {name, requirement} <- dependencies do
          true = Version.match?(Map.fetch!(versions, name), requirement)
        end

        Map.put(versions, app, version)
      end
    )
  after
    if source_override, do: System.put_env("LIBTMUX_SOURCE_DEPS", source_override)
  end

  archive = Path.join(root, "libtmux.tar")
  mix = System.find_executable("mix") || raise "mix is required"
  elixir = System.find_executable("elixir") || raise "elixir is required"
  {build_output, 0} = System.cmd(mix, ["hex.build", "--output", archive], stderr_to_stdout: true)
  IO.write(build_output)
  {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:memory])
  {_, contents} = List.keyfind(entries, ~c"contents.tar.gz", 0)
  {_, metadata} = List.keyfind(entries, ~c"metadata.config", 0)
  metadata_path = Path.join(root, "metadata.config")
  File.write!(metadata_path, metadata)
  {:ok, metadata_terms} = :file.consult(String.to_charlist(metadata_path))
  {"requirements", []} = List.keyfind(metadata_terms, "requirements", 0)

  package = Path.join(root, "package")
  consumer = Path.join(root, "consumer")
  File.mkdir!(package)
  File.mkdir!(consumer)

  :ok =
    :erl_tar.extract({:binary, contents}, [
      :compressed,
      {:cwd, String.to_charlist(package)}
    ])

  true = File.regular?(Path.join(package, "c_src/owned_io.c"))
  false = File.exists?(Path.join(package, "priv/native"))

  if :os.type() == {:unix, :linux} do
    {missing_output, missing_status} =
      System.cmd(mix, ["compile"],
        cd: package,
        env: [{"MIX_ENV", "prod"}, {"CC", "missing-libtmux-c-compiler"}],
        stderr_to_stdout: true
      )

    true = missing_status != 0
    true = String.contains?(missing_output, "requires a C11 compiler")
  end

  {compile_output, 0} =
    System.cmd(mix, ["compile", "--warnings-as-errors"],
      cd: package,
      env: [{"MIX_ENV", "prod"}],
      stderr_to_stdout: true
    )

  IO.write(compile_output)

  code = ~S"""
  {:ok, _} = Application.ensure_all_started(:libtmux)
  {:ok, ref} = LibTmux.Ref.new(:pane, "%7", "packed-instance")
  :ok = LibTmux.Ref.validate(ref, "packed-instance")
  {:error, %LibTmux.Error{kind: :stale_target}} = LibTmux.Ref.validate(ref, "other-instance")
  remaining = LibTmux.Deadline.new(1000) |> LibTmux.Deadline.remaining()
  true = remaining in 1..1000
  command = LibTmux.Command.new("display-message", ["-p", "hello;"])
  ["display-message", "-p", "hello\\;"] = LibTmux.Command.argv(command)
  true = is_binary(LibTmux.Command.render(command))
  {:ok, "hello\n"} = LibTmux.Codec.decode_field("hello\n\n", :string)
  {:ok, "hello\n"} = LibTmux.Codec.decode_field("v1:hello\\012\n", :string, encoding: :escaped_v1)
  true = String.starts_with?(LibTmux.Format.field("pane_title"), "v1:")
  true = is_binary(LibTmux.Format.literal(~S"#{pid}"))
  {:ok, [{:reply, :ok, {1, 2, 1}, ["hello"]}], parser} =
    LibTmux.Protocol.feed(LibTmux.Protocol.new(), "%begin 1 2 1\nhello\n%end 1 2 1\n")
  :ok = LibTmux.Protocol.finish(parser)
  {:ok, snapshot} = LibTmux.Snapshot.new(
    %{session: [%{id: "$0", name: "packed", attached_count: 2}]},
    server_instance: "packed-instance", captured_from: 1, captured_until: 2,
    fields: %{session: [:id, :name, :attached_count]}, complete: [:session]
  )
  [%LibTmux.Session{attached: true, attached_count: 2}] =
    LibTmux.Snapshot.items(snapshot, LibTmux.Session)
  if :os.type() == {:unix, :linux} do
    {:ok, %{stdout: "packed\n", stderr: "", exit_status: 0, cleanup: :retired}} =
      LibTmux.Transport.OneShot.run("/bin/echo", ["packed"], max_total_bytes: 7)
  else
    {:error, %LibTmux.Error{kind: :unsupported_platform}} =
      LibTmux.Transport.OneShot.run("/bin/echo", ["packed"])
  end
  IO.puts("packed core consumer: ok")
  """

  {"packed core consumer: ok\n", 0} =
    System.cmd(
      elixir,
      ["-pa", Path.join(package, "_build/prod/lib/libtmux/ebin"), "-e", code],
      cd: consumer,
      stderr_to_stdout: true
    )

  IO.puts("PASS: packed core imported outside the checkout; no Hex runtime dependencies")
after
  File.rm_rf!(root)
end
