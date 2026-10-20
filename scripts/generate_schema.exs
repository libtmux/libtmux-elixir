alias LibTmux.Schema

code = fn values -> Enum.map_join(values, ", ", &"`#{&1}`") end

sections =
  Enum.map(Schema.entities(), fn entity ->
    fields =
      for {name, field} <- Enum.sort(Schema.fields(entity)) do
        format = if field.format, do: "`#{field.format}`", else: "Derived"

        "| `#{name}` | `#{field.wire}` | `#{inspect(field.type)}` | #{format} | #{code.(Schema.operators(field))} |\n"
      end

    relations =
      for {name, {cardinality, target}} <- Enum.sort(Schema.relations(entity)) do
        operators =
          if cardinality == :one, do: [:is, :is_not], else: [:some, :every, :none, :count]

        "| `#{name}` | `#{Schema.relation_wire(name)}` | `#{cardinality}` | `#{target}` | #{code.(operators)} |\n"
      end

    [
      "## `#{entity}`\n\n",
      "| Elixir field | Wire field | Value category | tmux format | Operators |\n",
      "| --- | --- | --- | --- | --- |\n",
      fields,
      "\n",
      "| Relation | Wire relation | Cardinality | Target | Operators |\n",
      "| --- | --- | --- | --- | --- |\n",
      relations,
      "\n"
    ]
  end)

document =
  IO.iodata_to_binary([
    "# Observation and filter schema\n\n",
    "Generated from `LibTmux.Schema`; regenerate with `mix run scripts/generate_schema.exs`.\n",
    "All current fields use the tmux 3.3 capture baseline. Coverage must still be loaded.\n",
    "Only `nullable_integer` admits `nil`; other unavailable or unloaded fields raise.\n",
    "Link IDs are `{session_id, index, window_id}` locally and three-element arrays on the wire.\n",
    "See [filtering](filtering.md) for Boolean, relation and error semantics.\n\n",
    sections
  ])

path = Path.expand("../docs/schema.md", __DIR__)
document = String.trim_trailing(document) <> "\n"

case System.argv() do
  [] -> File.write!(path, document)
  ["--check"] -> if File.read!(path) != document, do: raise("generated schema is stale")
  _ -> raise ArgumentError, "expected no arguments or --check"
end
