defmodule LibTmux.PublicTypeCheck do
  @moduledoc false

  # ExDoc anchors only public and opaque types, so a private type named by a
  # public declaration renders as plain text. An opaque type renders its head
  # without a body, so its body may name private types.

  # `mix test --cover` reports cover-compiled modules as `:cover_compiled`, so
  # fall back to the object code on the code path.
  @doc "Resolves loaded modules to the beam files that `findings/1` reads."
  def beams(modules) do
    Enum.map(modules, fn module ->
      case :code.which(module) do
        path when is_list(path) and path != [] ->
          {module, List.to_string(path)}

        other ->
          case :code.get_object_code(module) do
            {^module, _binary, path} -> {module, List.to_string(path)}
            _ -> raise "no beam file for #{inspect(module)}: #{inspect(other)}"
          end
      end
    end)
  end

  @doc "Returns one sorted line for each public declaration that names a private type."
  def findings(beams) do
    subjects = Enum.map(beams, fn {module, path} -> {module, path, File.read!(path)} end)

    private =
      MapSet.new(
        for {module, _path, bytes} <- subjects,
            {:typep, {name, _body, parameters}} <- fetch!(Code.Typespec.fetch_types(bytes)),
            do: {module, name, length(parameters)}
      )

    subjects
    |> Enum.flat_map(&declarations/1)
    |> Enum.flat_map(fn {module, kind, name, arity, forms} ->
      for {target, target_name, target_arity} <- Enum.uniq(references(forms, module)),
          MapSet.member?(private, {target, target_name, target_arity}) do
        "#{inspect(module)}.#{name}/#{arity}: #{kind} names private type " <>
          "#{qualified(module, target, target_name, target_arity)}"
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp declarations({module, path, bytes}) do
    {:docs_v1, _, _, _, module_doc, _, entries} = fetch!(Code.fetch_docs(path))

    if module_doc == :hidden do
      []
    else
      shown =
        MapSet.new(
          for {{kind, name, arity}, _, _, doc, _} <- entries,
              doc != :hidden,
              do: {kind, name, arity}
        )

      types =
        for {:type, {name, body, parameters}} <- fetch!(Code.Typespec.fetch_types(bytes)),
            MapSet.member?(shown, {:type, name, length(parameters)}),
            do: {module, "type", name, length(parameters), [body]}

      specs =
        for {{name, arity}, forms} <- fetch!(Code.Typespec.fetch_specs(bytes)),
            {kind, public_name, public_arity} = function_identity(:function, name, arity),
            MapSet.member?(shown, {kind, public_name, public_arity}),
            do: {module, "spec", public_name, public_arity, forms}

      callbacks =
        for {{name, arity}, forms} <- fetch!(Code.Typespec.fetch_callbacks(bytes)),
            {kind, public_name, public_arity} = function_identity(:callback, name, arity),
            MapSet.member?(shown, {kind, public_name, public_arity}),
            do: {module, "callback", public_name, public_arity, forms}

      types ++ specs ++ callbacks
    end
  end

  # Macros are stored as `MACRO-name` with one extra argument for the caller.
  defp function_identity(kind, name, arity) do
    case Atom.to_string(name) do
      "MACRO-" <> macro ->
        {if(kind == :callback, do: :macrocallback, else: :macro), String.to_atom(macro),
         arity - 1}

      _ ->
        {kind, name, arity}
    end
  end

  defp references({:user_type, _anno, name, arguments}, module),
    do: [{module, name, length(arguments)} | references(arguments, module)]

  defp references(
         {:remote_type, _anno, [{:atom, _, target}, {:atom, _, name}, arguments]},
         module
       ),
       do: [{target, name, length(arguments)} | references(arguments, module)]

  defp references(term, module) when is_tuple(term),
    do: term |> Tuple.to_list() |> references(module)

  defp references(term, module) when is_list(term),
    do: Enum.flat_map(term, &references(&1, module))

  defp references(_term, _module), do: []

  defp qualified(module, module, name, arity), do: "#{name}/#{arity}"
  defp qualified(_module, target, name, arity), do: "#{inspect(target)}.#{name}/#{arity}"

  defp fetch!({:ok, result}), do: result
  defp fetch!({:docs_v1, _, _, _, _, _, _} = docs), do: docs
  defp fetch!(error), do: raise("cannot read compiled declarations: #{inspect(error)}")
end
