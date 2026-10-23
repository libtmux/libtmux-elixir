defmodule LibTmux.Server do
  @moduledoc """
  An explicit local tmux server descriptor.

  `new/1` performs no I/O. One-shot commands use an absolute executable and
  socket with `-N`, so they cannot start a missing server or attach a client.
  Configured server hooks remain environmental effects. Reads observe an
  interval; one-shot identity checks leave a check/use race. Persistent
  incarnation-bound mutations require a separately qualified connection.
  """

  alias LibTmux.{Capture, Command, Error}
  alias LibTmux.Transport.OneShot
  @enforce_keys [:executable, :socket, :cwd, :env]
  @derive {Inspect, only: []}
  defstruct [:executable, :socket, :cwd, :env]

  @typedoc "An explicit local server descriptor; constructing it neither connects nor reserves server identity."
  @type t :: %__MODULE__{
          executable: String.t(),
          socket: String.t(),
          cwd: String.t(),
          env: %{optional(binary()) => binary()}
        }
  @typedoc "Descriptor inputs; executable, socket and cwd are absolute NUL-free paths."
  @type option ::
          {:executable | :socket | :cwd, String.t()}
          | {:env, %{optional(binary()) => binary()}}

  @doc """
  Constructs a descriptor for an existing server without connecting or creating it.

  See the [worked example](first-task.html).
  """
  @spec new([option()]) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [:executable, :socket, cwd: File.cwd!(), env: System.get_env()])

    executable = Keyword.fetch!(options, :executable)
    socket = Keyword.fetch!(options, :socket)

    unless Enum.all?([executable, socket, options[:cwd]], fn value ->
             is_binary(value) and Path.type(value) == :absolute and
               :binary.match(value, <<0>>) == :nomatch
           end),
           do:
             raise(
               ArgumentError,
               "server executable, socket and cwd must be absolute NUL-free paths"
             )

    %__MODULE__{executable: executable, socket: socket, cwd: options[:cwd], env: options[:env]}
  end

  @doc """
  Runs one trusted command without attaching; returns bounded output and exit evidence.

  See the [worked example](advanced-execution.html).
  """
  @spec run(t(), Command.t(), [OneShot.option()]) :: {:ok, OneShot.result()} | {:error, Error.t()}
  def run(%__MODULE__{} = server, %Command{} = command, options \\ []) do
    arguments = ["-N", "-u", "-S", server.socket | Command.argv(command)]
    options = Keyword.merge([cwd: server.cwd, env: server.env], options)

    case OneShot.run(server.executable, arguments, options) do
      {:ok, %{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, result} ->
        code =
          if Regex.match?(~r/\Acan't find (?:pane|window|session):/, result.stderr),
            do: :not_found,
            else: :other

        {:error,
         %Error{kind: :command_error, phase: :command, details: Map.put(result, :code, code)}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Captures a new graph explicitly, with bounded work and read retries.

  See the [worked example](first-task.html).
  """
  @spec snapshot(t(), [Capture.option()]) :: {:ok, LibTmux.Snapshot.t()} | {:error, Error.t()}
  def snapshot(server, options \\ []), do: Capture.fetch(server, options)

  @doc """
  Captures a graph or raises the same structured capture error.

  See the [worked example](first-task.html).
  """
  @spec snapshot!(t(), [Capture.option()]) :: LibTmux.Snapshot.t()
  def snapshot!(server, options \\ []) do
    case snapshot(server, options) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> raise error
    end
  end
end
