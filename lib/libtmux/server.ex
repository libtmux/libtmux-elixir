defmodule LibTmux.Server do
  @moduledoc """
  Describes a local tmux server for capturing state and running commands.

  `new/1` takes an absolute `:executable` path and an absolute `:socket` path,
  which selects tmux's socket file with `-S`. Use `System.find_executable/1`
  to resolve a name such as `"tmux"` through PATH before construction. The
  optional `:cwd` and `:env` default to the caller's working directory and
  environment. Construction validates the path forms without checking that
  the executable or socket exists. A Server is an immutable value with
  nothing to close; constructing one neither connects to tmux nor starts it.
  Commands use `-N`, so a missing daemon is never started implicitly.

  ## What is on here

  Server describes the endpoint. In Elixir, observation, selection and action
  functions live in their own modules. Start with these groups:

  **Connecting.** `new/1` describes the server for one-shot commands, which do
  not attach a client. `LibTmux.Control.with_connection/2` attaches a control
  client to an existing session for a callback and closes it afterwards.
  `LibTmux.Control.start_link/1` and `LibTmux.Control.child_spec/1` support
  application supervision. See the [managed control guide](managed-control.html)
  for connection setup and the host's hook and command-alias requirements.

  **Finding one thing.** Capture with `snapshot/2`, then use
  `LibTmux.Selection.one/2` to require one match or
  `LibTmux.Selection.one_or_nil/2` to allow no match. Both reject multiple
  matches. `LibTmux.Ref.from_observation/1` turns the chosen observation into
  a reference tied to the daemon that supplied it, ready for an action.

  **Listing everything.** `snapshot/2` captures a `LibTmux.Snapshot` containing
  sessions, physical windows, window links, panes and attached clients.
  `LibTmux.Snapshot.sessions/1`, `LibTmux.Snapshot.windows/1`,
  `LibTmux.Snapshot.window_links/1`, `LibTmux.Snapshot.panes/1` and
  `LibTmux.Snapshot.clients/1` return selections from that captured graph
  without contacting tmux again. Capture failures return an error, not an
  empty server. Capture covers an interval rather than an atomic transaction;
  take another snapshot when fresh state is needed.

  **Querying things and getting around.** `LibTmux.Selection.where/2` accepts
  criteria such as `active: true`; `LibTmux.Selection.filter/2` accepts an
  Elixir function. Selections work with `Enum` and `Stream`. Navigate the
  captured graph with `LibTmux.Session.windows/2`, `LibTmux.Session.panes/2`,
  `LibTmux.Session.active_window/2` and `LibTmux.Window.panes/2`, or use
  `LibTmux.Snapshot.related/4` for other relationships. These functions use
  the supplied snapshot. Plural relationship helpers return lists; a
  `LibTmux.WindowLink` preserves a window's membership in one session.

  **Changing things.** `LibTmux.Pane.split/3` creates a pane and returns its ID
  in the completed result. A qualified Control connection also supplies a
  bound reference; one-shot split returns `ref: nil`. `LibTmux.Session.rename/4`
  and `LibTmux.Window.rename/4` change names. `LibTmux.Pane.send_text/4` sends
  literal bytes, while `LibTmux.Pane.send_keys/4` sends named keys such as
  `"Enter"`. These functions take a Server or Control connection followed by
  a reference. Domain bang variants return completed values or raise;
  nonbang variants return `{:ok, result}` for completed commands and
  `{:error, error}` otherwise. See the
  [action guide](one-shot-actions.html) and [recovery guide](recovery.html).

  **Reading screens, options and formats.** `LibTmux.Pane.capture/3` reads
  pane screen bytes through one-shot execution and requires a Server.
  On a control connection, `LibTmux.Control.execute/3`
  runs `LibTmux.Control.Request.field/2` reads and
  `LibTmux.Control.Request.set_user_option/2` server user-option writes.
  Use `LibTmux.Control.submit/3` and `LibTmux.Operation` when the result needs
  to remain available for independent inspection.

  Other tmux commands are available through `LibTmux.Command.new/2` and
  `run/3`, which runs one command with literal arguments and returns bounded
  output and exit evidence. Configured server hooks can still run. One-shot
  actions check the observed server identity before writing, leaving a race
  if the daemon is replaced between that check and the command. Use a
  qualified Control connection for mutations bound to one daemon instance.

  ## Examples

  Set `executable` to the absolute tmux executable and `socket` to the
  absolute socket path of the running server you want to inspect. This
  example captures once and lists each physical window's active pane:

      alias LibTmux.{Selection, Server, Snapshot}

      server =
        Server.new(
          executable: executable,
          socket: socket,
          env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
        )

      snapshot = Server.snapshot!(server)

      snapshot
      |> Snapshot.panes()
      |> Selection.where(active: true)
      |> Enum.map(& &1.id)

  The result is a list of pane IDs, such as `["%0", "%2"]`, with linked
  windows counted once. The [capture and filter guide](first-task.html) has
  a complete command-line program. For an isolated server and cleanup, use
  the [owned-server recipe](owned-server.html).
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
    options = Keyword.merge([cwd: server.cwd, env: server.env], options)

    case OneShot.run(server.executable, arguments(server, command), options) do
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

  @doc false
  def prepare_command(%__MODULE__{} = server, %Command{} = command) do
    LibTmux.Transport.Native.Protocol.prepare_process(
      server.executable,
      arguments(server, command),
      cwd: server.cwd,
      env: server.env
    )
  end

  defp arguments(server, command),
    do: ["-N", "-u", "-S", server.socket | Command.argv(command)]

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
