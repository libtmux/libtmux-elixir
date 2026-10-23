defmodule LibTmux.PublicTypesTest do
  # Fixture compilation changes VM-wide compiler options, so run apart.
  use ExUnit.Case, async: false

  Code.require_file("../scripts/check_public_types.exs", __DIR__)

  alias LibTmux.PublicTypeCheck

  @moduletag :tmp_dir

  test "no public type, spec or callback names a private type" do
    modules = Application.spec(:libtmux, :modules)

    assert PublicTypeCheck.findings(PublicTypeCheck.beams(modules)) == []
  end

  test "reports a public type, spec and callback that name a private type", %{tmp_dir: dir} do
    beams =
      compile(dir, """
      defmodule LibTmux.PublicTypesTest.Leaky do
        @moduledoc "Names a private type from every public declaration kind."

        @typep hidden :: integer()

        @typedoc "A public type."
        @type t :: %{hidden: hidden()}

        @callback load(hidden()) :: :ok

        @doc "A public function."
        @spec read(t()) :: hidden()
        def read(_value), do: 0
      end
      """)

    assert PublicTypeCheck.findings(beams) == [
             "LibTmux.PublicTypesTest.Leaky.load/1: callback names private type hidden/0",
             "LibTmux.PublicTypesTest.Leaky.read/1: spec names private type hidden/0",
             "LibTmux.PublicTypesTest.Leaky.t/0: type names private type hidden/0"
           ]
  end

  test "reports a private type named from a macro spec and a macro callback", %{tmp_dir: dir} do
    beams =
      compile(dir, """
      defmodule LibTmux.PublicTypesTest.Macros do
        @moduledoc "Names a private type from a macro and a macro callback."

        @typep hidden :: integer()

        @macrocallback expand(hidden()) :: Macro.t()

        @doc "A public macro."
        @spec twice(hidden()) :: Macro.t()
        defmacro twice(value), do: quote(do: unquote(value) * 2)
      end
      """)

    assert PublicTypeCheck.findings(beams) == [
             "LibTmux.PublicTypesTest.Macros.expand/1: callback names private type hidden/0",
             "LibTmux.PublicTypesTest.Macros.twice/1: spec names private type hidden/0"
           ]
  end

  test "reports a private type named from another module", %{tmp_dir: dir} do
    beams =
      compile(dir, """
      defmodule LibTmux.PublicTypesTest.Owner do
        @moduledoc "Owns a private type."
        @typep hidden :: integer()
        @typedoc "An opaque type that keeps the private type in use."
        @opaque shown :: {:shown, hidden()}
      end

      defmodule LibTmux.PublicTypesTest.Borrower do
        @moduledoc "Names the other module's private type."
        @doc "A public function."
        @spec read() :: LibTmux.PublicTypesTest.Owner.hidden()
        def read, do: 0
      end
      """)

    assert PublicTypeCheck.findings(beams) == [
             "LibTmux.PublicTypesTest.Borrower.read/0: spec names private type " <>
               "LibTmux.PublicTypesTest.Owner.hidden/0"
           ]
  end

  test "accepts public and opaque types and hidden declarations", %{tmp_dir: dir} do
    beams =
      compile(dir, """
      defmodule LibTmux.PublicTypesTest.Clean do
        @moduledoc "Names no private type from a documented declaration."

        @typep hidden :: integer()

        @typedoc "A public type."
        @type shown :: integer()

        @typedoc "An opaque type; its body is not rendered."
        @opaque wrapped :: {:wrapped, hidden()}

        @typedoc "A public type that composes public and opaque types."
        @type t :: %{shown: shown(), wrapped: wrapped()}

        @doc "A public function."
        @spec read(t()) :: shown()
        def read(_value), do: 0

        @doc false
        @spec skipped(hidden()) :: hidden()
        def skipped(value), do: value

        @doc "A public macro."
        @spec shown_macro(shown()) :: Macro.t()
        defmacro shown_macro(value), do: value

        @doc false
        @spec skipped_macro(hidden()) :: Macro.t()
        defmacro skipped_macro(value), do: value

        @spec internal(hidden()) :: hidden()
        defp internal(value), do: value
        def uses_internal, do: internal(0)
      end

      defmodule LibTmux.PublicTypesTest.Hidden do
        @moduledoc false
        @typep hidden :: integer()
        @type t :: hidden()
        @spec read() :: hidden()
        def read, do: 0
      end
      """)

    assert PublicTypeCheck.findings(beams) == []
  end

  # `mix test` compiles without debug info and docs; the check reads both.
  defp compile(dir, source) do
    options = Code.compiler_options()
    on_exit(fn -> Code.compiler_options(Keyword.new(Map.take(options, [:debug_info, :docs]))) end)
    Code.compiler_options(debug_info: true, docs: true)

    {modules, _diagnostics} =
      Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

    on_exit(fn ->
      for {module, _binary} <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    for {module, binary} <- modules do
      path = Path.join(dir, "#{module}.beam")
      File.write!(path, binary)
      {module, path}
    end
  end
end
