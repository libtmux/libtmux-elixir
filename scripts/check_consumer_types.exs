Code.put_compiler_option(:infer_signatures, [:elixir, :libtmux])

root = Path.expand("../test/fixtures/compiler", __DIR__)

cases = [
  {"valid.ex", :clean, nil},
  {"invalid_parser.ex", :warning, "incompatible types"},
  {"invalid_reference.ex", :warning, "unknown key .width"},
  {"invalid_operation.ex", :warning, "unknown key .exit_status"},
  {"dependent_codec.ex", :warning, "incompatible types"},
  {"dependent_action.ex", :observe, nil}
]

results =
  for {file, expectation, expected_message} <- cases do
    path = Path.join(root, file)

    {_modules, diagnostics} =
      Code.with_diagnostics([log: false], fn -> Code.compile_file(path) end)

    valid =
      case expectation do
        :clean ->
          diagnostics == []

        :warning ->
          Enum.any?(diagnostics, &(&1.severity == :warning and &1.message =~ expected_message))

        :observe ->
          true
      end

    %{
      file: file,
      expectation: expectation,
      passed: valid,
      diagnostics: Enum.map(diagnostics, &Map.take(&1, [:severity, :message]))
    }
  end

IO.puts(JSON.encode!(%{elixir: System.version(), cases: results}))

unless Enum.all?(results, & &1.passed),
  do: raise("consumer compilation did not produce the expected type diagnostics")
