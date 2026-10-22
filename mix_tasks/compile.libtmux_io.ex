defmodule Mix.Tasks.Compile.LibtmuxIo do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_arguments) do
    if :os.type() == {:unix, :linux} do
      source = Path.expand("c_src/owned_io.c")

      directory =
        Path.join(["priv", "native", :erlang.system_info(:system_architecture) |> to_string()])

      executable = Path.join(directory, "libtmux_io")
      stamp = executable <> ".sha256"
      compiler = System.get_env("CC", "cc")
      flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
      digest = :crypto.hash(:sha256, [File.read!(source), compiler, flags]) |> Base.encode16()

      if File.read(stamp) == {:ok, digest} and File.exists?(executable) do
        {:noop, []}
      else
        cc =
          System.find_executable(compiler) ||
            Mix.raise(
              "libtmux requires a C11 compiler to build its Linux I/O helper; install cc or set CC to one executable"
            )

        File.mkdir_p!(directory)
        temporary = executable <> ".#{System.pid()}"

        try do
          case System.cmd(cc, flags ++ ["-o", temporary, source], stderr_to_stdout: true) do
            {_output, 0} ->
              File.rename!(temporary, executable)
              File.write!(stamp, digest)
              {:ok, []}

            {output, status} ->
              Mix.raise("libtmux I/O helper compilation failed (#{status}):\n#{output}")
          end
        after
          File.rm(temporary)
        end
      end
    else
      {:noop, []}
    end
  end

  @impl true
  def clean, do: File.rm_rf!("priv/native")
end
