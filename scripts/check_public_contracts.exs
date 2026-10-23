Code.require_file("check_public_types.exs", __DIR__)

modules = Application.spec(:libtmux, :modules) || raise "compile the libtmux application first"

modules =
  Enum.map(modules, fn module ->
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, _} = docs -> {module, docs}
      error -> raise "missing compiled documentation for #{inspect(module)}: #{inspect(error)}"
    end
  end)

rows =
  for {module, {:docs_v1, _, _, _, module_doc, _, docs}} <- modules,
      module_doc != :hidden do
    {:ok, specs} = Code.Typespec.fetch_specs(module)
    {:ok, types} = Code.Typespec.fetch_types(module)
    specified = MapSet.new(specs, &elem(&1, 0))
    entries = Map.new(docs, fn {id, _, _, doc, _} -> {id, doc} end)

    documented? = fn doc ->
      is_map(doc) and Enum.any?(doc, fn {_, text} -> String.trim(text) != "" end)
    end

    functions =
      for {{kind, name, arity}, _, _, doc, _} <- docs,
          kind in [:function, :macro] and doc != :hidden and name != :__struct__ do
        %{
          name: Atom.to_string(name),
          arity: arity,
          spec: MapSet.member?(specified, {name, arity}),
          doc: documented?.(doc)
        }
      end

    types =
      for {visibility, {name, _, parameters}} <- types,
          visibility in [:type, :opaque] do
        arity = length(parameters)

        %{
          name: Atom.to_string(name),
          arity: arity,
          visibility: visibility,
          typedoc: documented?.(Map.get(entries, {:type, name, arity}))
        }
      end

    %{module: inspect(module), functions: functions, types: types}
  end

missing =
  Enum.flat_map(rows, fn row ->
    for {kind, entries, key} <- [
          {:function, row.functions, :spec},
          {:function, row.functions, :doc},
          {:type, row.types, :typedoc}
        ],
        entry <- entries,
        not Map.fetch!(entry, key) do
      "#{row.module}.#{entry.name}/#{entry.arity}: missing #{kind} #{key}"
    end
  end)

private_types =
  LibTmux.PublicTypeCheck.findings(LibTmux.PublicTypeCheck.beams(Enum.map(modules, &elem(&1, 0))))

report = %{
  elixir: System.version(),
  otp: List.to_string(:erlang.system_info(:otp_release)),
  modules: Enum.sort_by(rows, & &1.module),
  public_modules: length(rows),
  public_functions: Enum.sum(Enum.map(rows, &length(&1.functions))),
  public_types: Enum.sum(Enum.map(rows, &length(&1.types))),
  missing: missing,
  private_types: private_types,
  scope:
    "Compiled public declarations; coverage does not prove contract accuracy or compiler inference."
}

if rows == [], do: raise("no public documentation found in the compiled application")

case System.argv() do
  [] -> :ok
  ["--output", path] -> File.write!(path, JSON.encode!(report) <> "\n", [:exclusive])
  _ -> raise ArgumentError, "expected no arguments or --output PATH"
end

IO.puts(JSON.encode!(Map.drop(report, [:modules, :scope])))
if missing != [], do: raise("public contract declarations are incomplete")
if private_types != [], do: raise("public declarations name private types")
