defmodule LibTmux.Server do
  @moduledoc """
  Describes a local tmux server for capturing state and running commands.

  `new/1` takes an absolute `:executable` path. Use
  `System.find_executable/1` to resolve a name such as `"tmux"` through PATH
  before construction. The optional `:cwd` and `:env` default to the caller's
  working directory and environment. Construction validates the path forms
  without checking that the executable or socket exists. A Server is an
  immutable value; constructing one with `new/1` neither connects to tmux nor
  starts it. Commands use `-N`, so a missing daemon is never started
  implicitly. `start/1` and `with_owned/2` start a private server and return
  a Server that `stop/2` can retire.

  ## Choosing the server

  `new/1` picks the socket in this order, and the first rule that applies
  wins:

  1. `:socket`, an absolute socket path, passes `-S`.
  2. `:socket_name`, a socket name, passes `-L`. Pass at most one of
     `:socket` and `:socket_name`.
  3. The `LIBTMUX_SOCKET_PATH` variable passes `-S` with its path.
  4. The `LIBTMUX_SOCKET` variable passes `-L` with its name.
  5. Otherwise no socket is passed, and tmux chooses. It follows the server
     that `TMUX` names when `:env` has one, and otherwise uses its default
     socket: `default` in the `tmux-UID` directory of `TMUX_TMPDIR`, or of
     `/tmp`.

  An explicit option ignores both variables, even an invalid one. When both
  variables are set, the path wins, as `-S` does over `-L` in tmux. A variable
  that is empty counts as unset, each one alone. The variables come from the
  `:env` option, which defaults to the caller's environment, so a Server built
  with its own `:env` ignores the caller's variables. A set variable with an
  invalid value raises `ArgumentError` that names the variable and never
  repeats its value.

  The choice is made once, in `new/1`, and `t:t/0` records it. A Server that
  chose a socket removes `TMUX` and `TMUX_PANE` from the environment it gives
  tmux, so a surrounding tmux session cannot redirect it. A Server that chose
  none keeps both, for one-shot execution and for control connections alike,
  so a program run inside tmux reaches the server it runs in. Leave `TMUX` out
  of `:env` to send a Server with no socket to tmux's default socket instead.

  ## What is on here

  Server describes the endpoint. In Elixir, observation, selection and action
  functions live in their own modules. Start with these groups:

  **Connecting.** Describe the server for one-shot commands, which do not attach
  a client. Attach a control client to an existing session for the length of a
  callback; the client closes afterwards. Run a control client under application
  supervision. See the [managed control guide](managed-control.html) for
  connection setup and the host's hook and command-alias requirements.

  - Describe: `new/1`
  - Attach for a callback: `LibTmux.Control.with_connection/2`
  - Supervise: `LibTmux.Control.start_link/1`, `LibTmux.Control.child_spec/1`

  **Owning a private server.** Start a tmux server in a private directory,
  with no inherited `TMUX` or `TMUX_PANE`, and stop it when you are done.
  `with_owned/2` does both around a function, so a program needs no shell step
  to start or clean up tmux. The process that starts the server owns it, and the
  server stops when that process exits. `stop/2` refuses a Server that
  `start/1` did not create; `kill/2` sends `kill-server` to any Server.

  - Start and stop around a function: `with_owned/2`
  - Start: `start/1`
  - Stop: `stop/2`
  - Kill any server: `kill/2`
  - Raise on failure: `kill!/2`

  **Finding one thing.** Capture a snapshot, then require one match or allow no
  match. Both reject multiple matches. Turn the chosen observation into a
  reference tied to the daemon that supplied it, ready for an action.

  - Capture: `snapshot/2`
  - Require one: `LibTmux.Selection.one/2`
  - Allow none: `LibTmux.Selection.one_or_nil/2`
  - Reference: `LibTmux.Ref.from_observation/1`

  **Listing everything.** Capture sessions, physical windows, window links, panes
  and attached clients as a `LibTmux.Snapshot`. One accessor per kind returns a
  selection from that captured graph without contacting tmux again. Capture
  failures return an error, not an empty server. Capture covers an interval
  rather than an atomic transaction; take another snapshot when fresh state is
  needed.

  - Capture: `snapshot/2`
  - Select: `LibTmux.Snapshot.sessions/1`, `LibTmux.Snapshot.windows/1`,
    `LibTmux.Snapshot.window_links/1`, `LibTmux.Snapshot.panes/1`,
    `LibTmux.Snapshot.clients/1`

  **Querying things and getting around.** Select by criteria such as
  `active: true`, or by an Elixir function; selections work with `Enum` and
  `Stream`. Navigation functions use the supplied snapshot. Plural helpers return
  selections for further filtering; a `LibTmux.WindowLink` preserves a window's
  membership in one session.

  - By criteria: `LibTmux.Selection.where/2`
  - By function: `LibTmux.Selection.filter/2`
  - Down: `LibTmux.Session.windows/2`, `LibTmux.Session.panes/2`,
    `LibTmux.Window.panes/2`
  - Focused: `LibTmux.Session.active_window/2`
  - Other relationships: `LibTmux.Snapshot.related/4`

  **Changing things.** Create detached sessions and windows on an existing server
  using one-shot execution. Each returns the created ID with `ref: nil`; capture
  a fresh observation to obtain a reference. Split a pane to create a pane and
  get its ID in the completed result. A qualified Control connection also
  supplies a bound reference; one-shot split returns `ref: nil`. Rename a session
  or a window. Send literal bytes or named keys such as `"Enter"` to a pane.
  Split, rename and input take a Server or Control connection followed by a
  reference. Domain bang variants return completed values or raise; nonbang
  variants return `{:ok, result}` for completed commands and `{:error, error}`
  otherwise. See the [action guide](one-shot-actions.html) and
  [recovery guide](recovery.html).

  - Create: `new_session/3`, `LibTmux.Session.new_window/4`
  - Split: `LibTmux.Pane.split/3`
  - Rename: `LibTmux.Session.rename/4`, `LibTmux.Window.rename/4`
  - Send literal bytes: `LibTmux.Pane.send_text/4`
  - Send named keys: `LibTmux.Pane.send_keys/4`

  **Reading screens, options and formats.** Capture pane screen bytes through
  one-shot execution, which requires a Server. On a control connection, execute a
  request that reads a field or writes a server user option. Submit the request
  and keep the returned `LibTmux.Operation` when the result needs to remain
  available for independent inspection.

  - Screen: `LibTmux.Pane.capture/3`
  - Execute: `LibTmux.Control.execute/3`
  - Read a field: `LibTmux.Control.Request.field/2`
  - Write a user option: `LibTmux.Control.Request.set_user_option/2`
  - Submit: `LibTmux.Control.submit/3`

  **Running any other command.** Build a command to run any other tmux command.
  Running executes one command with literal arguments and returns bounded output
  and exit evidence. Configured server hooks can still run. Targeted one-shot
  actions check the observed server identity before writing, leaving a race if
  the daemon is replaced between that check and the command. Use a qualified
  Control connection for mutations bound to one daemon instance.

  - Build: `LibTmux.Command.new/2`
  - Run: `run/3`

  ## Examples

  Start a private server for the length of a function. This creates a
  session, lists its panes, and leaves nothing behind:

      alias LibTmux.{Selection, Server, Snapshot}

      tmux = System.find_executable("tmux")

      Server.with_owned([executable: tmux], fn server ->
        {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})

        server
        |> Server.snapshot!()
        |> Snapshot.panes()
        |> Enum.map(& &1.id)
      end)

  The result is `["%0"]`. To inspect a server that already runs, set
  `executable` to the absolute tmux executable and `socket` to the
  absolute socket path of that server. Leave out
  `socket` to follow `LIBTMUX_SOCKET_PATH`, `LIBTMUX_SOCKET` or tmux's default
  socket. This example captures once and lists each physical window's active
  pane:

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

  @invalid_paths "server executable, socket and cwd must be absolute NUL-free paths"
  @invalid_name "one file name with no slash or NUL byte, and not a dot directory entry"

  @enforce_keys [:executable, :cwd, :env]
  @derive {Inspect, only: []}
  defstruct [:executable, :socket, :socket_name, :cwd, :env, :daemon]

  @typedoc """
  A local server descriptor; constructing it neither connects nor reserves server identity.

  At most one of `:socket` and `:socket_name` is set. Both are `nil` when tmux
  chooses its default socket. `daemon` names the process that owns a server
  created by `start/1`, and is `nil` for every other Server.
  """
  @type t :: %__MODULE__{
          executable: String.t(),
          socket: String.t() | nil,
          socket_name: String.t() | nil,
          cwd: String.t(),
          env: %{optional(binary()) => binary()},
          daemon: pid() | nil
        }
  @typedoc """
  Descriptor inputs.

  The executable, `:socket` and cwd are absolute NUL-free paths. `:socket_name`
  is a single file name without a slash or NUL that is not `.` or `..`.
  """
  @type option ::
          {:executable | :socket | :socket_name | :cwd, String.t()}
          | {:env, %{optional(binary()) => binary()}}

  @doc """
  Constructs a descriptor for an existing server without connecting or creating it.

  `:socket` selects the socket by path and `:socket_name` by name; pass at most
  one. With neither, the descriptor reads `LIBTMUX_SOCKET_PATH`, then
  `LIBTMUX_SOCKET`, from `:env`, and selects no socket when neither is set, so
  tmux uses its default. See "Choosing the server" in the module
  documentation. Raises `ArgumentError` for conflicting or invalid input,
  naming a variable but never its value.

  See the [worked example](first-task.html).
  """
  @spec new([option()]) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [
        :executable,
        :socket,
        :socket_name,
        cwd: File.cwd!(),
        env: System.get_env()
      ])

    executable = Keyword.fetch!(options, :executable)

    unless path?(executable) and path?(options[:cwd]),
      do: raise(ArgumentError, @invalid_paths)

    {socket, socket_name} =
      case Keyword.take(options, [:socket, :socket_name]) do
        [] -> from_environment(options[:env])
        [{:socket, socket}] -> {path!(socket, @invalid_paths), nil}
        [{:socket_name, name}] -> {nil, name!(name, ":socket_name must be #{@invalid_name}")}
        [_, _] -> raise ArgumentError, "pass at most one of :socket and :socket_name"
      end

    %__MODULE__{
      executable: executable,
      socket: socket,
      socket_name: socket_name,
      cwd: options[:cwd],
      env: options[:env]
    }
  end

  defp from_environment(env) do
    cond do
      path = variable(env, "LIBTMUX_SOCKET_PATH") ->
        {path!(path, "LIBTMUX_SOCKET_PATH must be an absolute NUL-free path"), nil}

      name = variable(env, "LIBTMUX_SOCKET") ->
        {nil, name!(name, "LIBTMUX_SOCKET must be #{@invalid_name}")}

      true ->
        {nil, nil}
    end
  end

  defp variable(env, name) when is_map(env) do
    case Map.get(env, name) do
      "" -> nil
      value -> value
    end
  end

  defp variable(_env, _name), do: nil

  defp path?(value),
    do:
      is_binary(value) and Path.type(value) == :absolute and
        :binary.match(value, <<0>>) == :nomatch

  defp path!(value, message),
    do: if(path?(value), do: value, else: raise(ArgumentError, message))

  defp name!(value, message),
    do: if(name?(value), do: value, else: raise(ArgumentError, message))

  defp name?(value),
    do:
      is_binary(value) and value not in ["", ".", ".."] and
        :binary.match(value, [<<0>>, "/"]) == :nomatch

  @typedoc """
  Inputs for `start/1`.

  `:executable` is required. `:root` is the directory that holds the private
  directory and defaults to `System.tmp_dir!/0`. `:config_file` defaults to
  `"/dev/null"`. `:env` overlays the daemon's environment; `TMUX` and
  `TMUX_PANE` never reach it. `:timeout` bounds startup, in milliseconds.
  """
  @type start_option ::
          {:executable, String.t()}
          | {:root, String.t()}
          | {:config_file, String.t()}
          | {:env, %{optional(binary()) => binary()}}
          | {:timeout, 1..600_000}

  @doc """
  Starts a private tmux server and returns a Server for it.

  The server runs in the foreground under libtmux's native helper, in a
  directory of its own below `:root`: the directory has mode 700, holds the
  socket and is `TMUX_TMPDIR` for the daemon and its panes. The daemon never
  inherits `TMUX` or `TMUX_PANE`, reads `:config_file` (an empty file by
  default), and stays up with no session. `start/1` returns when the socket
  answers, or when `:timeout` (5000 ms by default) ends.

  The process that calls `start/1` owns the server. When it exits, the daemon
  stops and its directory is removed. If the VM is killed, the native helper
  still retires the daemon, but the directory stays. Other processes may use
  the returned Server. Stop it with `stop/2` as soon as the work is done, or
  use `with_owned/2`.

  Returns `{:error, error}` for an invalid option, a socket path that would
  exceed the 107 usable bytes of `sun_path`, a daemon that cannot start or
  exits before it answers, and a timeout. A failed start leaves no directory
  behind. It starts only on Linux, like the rest of libtmux.

      alias LibTmux.Server

      {:ok, server} = Server.start(executable: System.find_executable("tmux"))
      {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
      :ok = Server.stop(server)
  """
  @spec start([start_option()]) :: {:ok, t()} | {:error, Error.t()}
  def start(options), do: LibTmux.Server.Daemon.start(options, self())

  @doc """
  Stops a server that `start/1` created and removes its directory.

  Sends `kill-server`, waits until the native helper proves that the daemon
  has exited, and removes the directory. Stopping a server
  that already stopped returns `:ok`. If the daemon still answers when
  `:timeout` (5000 ms by default) ends, or the directory cannot be removed,
  it returns `{:error, error}` and keeps the directory; call it again to
  retry.

  Returns `{:error, error}` with kind `:not_owned` for a Server that `new/1`
  built or that another process started and already stopped.
  """
  @spec stop(t(), [{:timeout, 1..600_000}]) :: :ok | {:error, Error.t()}
  def stop(server, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5000)

    unless Keyword.keys(options) -- [:timeout] == [] and is_integer(timeout) and
             timeout in 1..600_000,
           do: raise(ArgumentError, "the only stop option is :timeout, in 1..600000 ms")

    LibTmux.Server.Daemon.stop(server, timeout)
  end

  @doc """
  Starts a private server, calls `fun` with it and stops it afterwards.

  Takes the options of `start/1`. Returns the value of `fun`. A start failure
  raises its `LibTmux.Error` before `fun` runs. The server stops when `fun`
  returns, raises, throws or exits. If `fun` completes and the stop fails,
  `with_owned/2` raises the stop error; a failing stop never replaces an
  exception from `fun`.

      alias LibTmux.Server

      Server.with_owned([executable: System.find_executable("tmux")], fn server ->
        {:ok, _} = Server.new_session(server, "demo", command: {:argv, ["/bin/cat"]})
        Server.snapshot!(server)
      end)
  """
  @spec with_owned([start_option()], (t() -> result)) :: result when result: term()
  def with_owned(options, fun) when is_function(fun, 1) do
    case start(options) do
      {:ok, server} ->
        outcome =
          try do
            {:ok, fun.(server)}
          catch
            kind, reason -> {kind, reason, __STACKTRACE__}
          end

        stopped = stop(server)

        case {outcome, stopped} do
          {{:ok, value}, :ok} -> value
          {{:ok, _value}, {:error, error}} -> raise error
          {{kind, reason, stacktrace}, _stopped} -> :erlang.raise(kind, reason, stacktrace)
        end

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Kills the server with `kill-server`, whoever started it.

  Returns `{:ok, result}` when tmux acknowledges the command and
  `{:error, error}` otherwise, for example when no server answers. The
  command ends every session and pane on the server. It does not remove the
  directory of a server from `start/1`; use `stop/2` for that. The only
  option is `timeout` (5000 ms by default). See `LibTmux.Action` for outcomes.

      alias LibTmux.Server

      Server.kill(server)
  """
  @spec kill(t(), [LibTmux.Action.option()]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def kill(server, options \\ []),
    do: LibTmux.Action.run(:kill_server, server, nil, nil, options)

  @doc "Returns `:ok` when `kill/2` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec kill!(t(), [LibTmux.Action.option()]) :: :ok
  def kill!(server, options \\ []), do: server |> kill(options) |> LibTmux.Action.unwrap()

  @doc """
  Creates a named detached session on an existing server through one-shot execution.

  Returns `{:ok, result}` on completion, with `%{id: session_id, ref: nil}`
  as its value. Capture a fresh observation for a bound reference. There is
  no observed target to validate; this command acts on the server answering
  at the descriptor's endpoint. It never starts a missing server. A missing
  endpoint or duplicate session name returns an error with execution evidence.
  Control connections are unsupported.

  Names contain 1..1024 UTF-8 bytes without control characters. Format syntax
  stays literal; tmux's version-dependent name normalization still applies.
  Options are `timeout` (5000ms), literal `cwd`, and `command`: `:default`,
  `{:shell, nonempty_bytes}` or `{:argv, [program | arguments]}`. Command forms
  follow `LibTmux.Pane.split/3`, except `:empty` is unsupported for creation.
  Acknowledgement does not prove that the program started or finished.
  See `LibTmux.Action` for completion and failure handling.

      alias LibTmux.Server

      Server.new_session(server, "extra-work", command: {:argv, ["/bin/cat"]})
  """
  @spec new_session(t(), binary(), [LibTmux.Action.creation_option()]) ::
          {:ok, LibTmux.Action.result(LibTmux.Action.creation_value())}
          | {:error, LibTmux.Action.error()}
  def new_session(server, name, options \\ []),
    do: LibTmux.Action.run(:new_session, server, nil, name, options)

  @doc "Returns the created session value when `new_session/3` completes; raises the original error otherwise."
  @spec new_session!(t(), binary(), [LibTmux.Action.creation_option()]) ::
          LibTmux.Action.creation_value()
  def new_session!(server, name, options \\ []),
    do: server |> new_session(name, options) |> LibTmux.Action.unwrap()

  @doc """
  Runs one trusted command without attaching; returns bounded output and exit evidence.

  The options are those of `LibTmux.Transport.OneShot.run/3`, except
  `:keep_tmux_context`: the Server decides it from its socket, and a value
  passed here is ignored. Raises `ArgumentError` for a Server built by hand
  whose `socket` or `socket_name` is not `nil` or a string, or that sets both.

  See the [worked example](advanced-execution.html).
  """
  @spec run(t(), Command.t(), [OneShot.option()]) :: {:ok, OneShot.result()} | {:error, Error.t()}
  def run(%__MODULE__{} = server, %Command{} = command, options \\ []) do
    options =
      [cwd: server.cwd, env: server.env]
      |> Keyword.merge(options)
      |> Keyword.put(:keep_tmux_context, follows_tmux?(server))

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
      env: server.env,
      keep_tmux_context: follows_tmux?(server)
    )
  end

  @doc false
  def follows_tmux?(%__MODULE__{socket: nil, socket_name: nil}), do: true
  def follows_tmux?(%__MODULE__{}), do: false

  defp arguments(server, command),
    do: ["-N", "-u" | socket_arguments(server)] ++ Command.argv(command)

  @doc false
  def socket_arguments(%__MODULE__{socket: nil, socket_name: nil}), do: []

  def socket_arguments(%__MODULE__{socket: socket, socket_name: nil}) when is_binary(socket),
    do: ["-S", socket]

  def socket_arguments(%__MODULE__{socket: nil, socket_name: name}) when is_binary(name),
    do: ["-L", name]

  def socket_arguments(%__MODULE__{}),
    do: raise(ArgumentError, "a server names at most one socket, as a string")

  @doc false
  def valid_socket?(%__MODULE__{socket: nil, socket_name: nil}), do: true

  def valid_socket?(%__MODULE__{socket: socket, socket_name: nil}),
    do: path?(socket) and byte_size(socket) <= 32_000

  def valid_socket?(%__MODULE__{socket: nil, socket_name: name}),
    do: name?(name)

  def valid_socket?(%__MODULE__{}), do: false

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
