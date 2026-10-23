defmodule LibTmux.Session do
  @moduledoc "An immutable session observation with explicit actions. Attachment retains tmux's client count."
  @enforce_keys [:id, :server_instance]
  defstruct [
    :id,
    :server_instance,
    name: :unloaded,
    attached_count: :unloaded,
    attached: :unloaded
  ]

  @typedoc "A session with explicit field coverage and an attachment count separate from its Boolean projection."
  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          name: LibTmux.Schema.observed(String.t()),
          attached_count: LibTmux.Schema.observed(non_neg_integer()),
          attached: LibTmux.Schema.observed(boolean())
        }

  @doc """
  Renames an exact session through the selected transport; returns an action result.

  Names contain 1..1024 UTF-8 bytes without Unicode control characters (Cc).
  Format syntax remains literal;
  tmux still normalizes names (including dollar/backslash escaping, and dots
  and colons on older releases). The only option is `timeout`, which defaults
  to 5000ms.
  Old observations stay unchanged. See `LibTmux.Action` for outcome semantics.

      Session.rename(server, session_ref, "work")
  """
  @spec rename(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Control.call_option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def rename(connection, ref, name, options \\ []),
    do: LibTmux.Action.run(:rename_session, connection, ref, name, options)

  @doc "Renames as in `rename/4`, raising API errors while preserving canonical failed outcomes."
  @spec rename!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Control.call_option()
        ]) :: LibTmux.Action.result(:ok)
  def rename!(connection, ref, name, options \\ []),
    do: connection |> rename(ref, name, options) |> LibTmux.Action.unwrap()
end

defmodule LibTmux.Window do
  @moduledoc "An immutable physical window with explicit actions, independent of session membership and index."
  @enforce_keys [:id, :server_instance]
  defstruct [
    :id,
    :server_instance,
    name: :unloaded,
    width: :unloaded,
    height: :unloaded,
    layout: :unloaded,
    zoomed: :unloaded
  ]

  @typedoc "A physical window; session index and active-window state belong to a WindowLink."
  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          name: LibTmux.Schema.observed(String.t()),
          width: LibTmux.Schema.observed(non_neg_integer()),
          height: LibTmux.Schema.observed(non_neg_integer()),
          layout: LibTmux.Schema.observed(String.t()),
          zoomed: LibTmux.Schema.observed(boolean())
        }

  @doc """
  Renames an exact physical window across all its memberships.

  Names contain 1..1024 UTF-8 bytes without Unicode control characters (Cc),
  with literal format syntax.
  tmux still applies name normalization, including dollar/backslash escaping.
  Control characters fail before I/O on both transports. Optional `session: session_ref` requires
  membership in that exact session; it does not select a captured link index.
  `timeout` defaults to 5000ms. See `LibTmux.Action` for transport and outcomes.

      Window.rename(control, window_ref, "editor")
  """
  @spec rename(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [LibTmux.Action.option()]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def rename(connection, ref, name, options \\ []),
    do: LibTmux.Action.run(:rename_window, connection, ref, name, options)

  @doc "Renames as in `rename/4`, raising API errors while preserving canonical failed outcomes."
  @spec rename!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [LibTmux.Action.option()]) ::
          LibTmux.Action.result(:ok)
  def rename!(connection, ref, name, options \\ []),
    do: connection |> rename(ref, name, options) |> LibTmux.Action.unwrap()
end

defmodule LibTmux.WindowLink do
  @moduledoc "An observed session/index/window binding. Its key is not a link lifetime ID."
  @enforce_keys [:id, :server_instance]
  defstruct [
    :id,
    :server_instance,
    session_id: :unloaded,
    window_id: :unloaded,
    index: :unloaded,
    active: :unloaded
  ]

  @typedoc "A captured session/index/window binding, including its session-relative active state."
  @type t :: %__MODULE__{
          id: {String.t(), non_neg_integer(), String.t()},
          server_instance: String.t(),
          session_id: LibTmux.Schema.observed(String.t()),
          window_id: LibTmux.Schema.observed(String.t()),
          index: LibTmux.Schema.observed(non_neg_integer()),
          active: LibTmux.Schema.observed(boolean())
        }
end

defmodule LibTmux.Pane do
  @moduledoc "An immutable physical pane with explicit actions. It belongs to a window; text may be empty."
  @enforce_keys [:id, :server_instance]
  defstruct [
    :id,
    :server_instance,
    window_id: :unloaded,
    index: :unloaded,
    active: :unloaded,
    dead: :unloaded,
    width: :unloaded,
    height: :unloaded,
    pid: :unloaded,
    current_command: :unloaded,
    current_path: :unloaded,
    title: :unloaded,
    exit_status: :unloaded
  ]

  @typedoc "A physical pane; exit status can be known absent, while other missing fields retain coverage sentinels."
  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          window_id: LibTmux.Schema.observed(String.t()),
          index: LibTmux.Schema.observed(non_neg_integer()),
          active: LibTmux.Schema.observed(boolean()),
          dead: LibTmux.Schema.observed(boolean()),
          width: LibTmux.Schema.observed(non_neg_integer()),
          height: LibTmux.Schema.observed(non_neg_integer()),
          pid: LibTmux.Schema.observed(non_neg_integer()),
          current_command: LibTmux.Schema.observed(String.t()),
          current_path: LibTmux.Schema.observed(String.t()),
          title: LibTmux.Schema.observed(String.t()),
          exit_status: LibTmux.Schema.observed(non_neg_integer() | nil)
        }

  @typedoc "Split geometry and process arguments; the returned ID identifies the newly created physical pane."
  @type split_option ::
          LibTmux.Action.option()
          | {:axis, :horizontal | :vertical}
          | {:size, {:cells, 1..32_767} | {:percent, 1..99}}
          | {:before | :detached, boolean()}
          | {:cwd, binary()}
          | {:command, [binary()]}
  @typedoc "Bounded one-shot screen capture; line numbers are relative to the visible screen, with negative history offsets."
  @type capture_option ::
          LibTmux.Action.option()
          | {:start_line, -32_768..32_767}
          | {:end_line, -32_768..32_767 | :last}
          | {:join_lines, boolean()}
          | {:max_bytes, 0..1_048_576}

  @doc """
  Splits an exact pane and returns an acknowledged created pane ID as `value`.

  Defaults: vertical split, half size, detached, after the target, and tmux's
  session default shell/command and directory. `axis: :horizontal` places panes
  side by side; `size: {:percent, n}` uses `-l n%` on every supported release.
  Optional `cwd` is literal format text. `command` follows tmux: zero entries
  uses the session default, one is a shell command, two or more are direct argv.
  At most 64 entries and the existing command byte bounds apply.

  `session: session_ref` selects exact membership/context, not a WindowLink
  index. `timeout` defaults to 5000ms. No snapshot is changed; capture again
  when a new observation is needed. See `LibTmux.Action` for outcomes and the
  one-shot identity check/use limitation.

      Pane.split(control, pane_ref, axis: :horizontal, size: {:percent, 30})
  """
  @spec split(LibTmux.Action.connection(), LibTmux.Ref.t(), [split_option()]) ::
          {:ok, LibTmux.Action.result(String.t())} | {:error, LibTmux.Action.error()}
  def split(connection, ref, options \\ []),
    do: LibTmux.Action.run(:split, connection, ref, nil, options)

  @doc "Splits as in `split/3`, raising API errors while preserving canonical failed outcomes."
  @spec split!(LibTmux.Action.connection(), LibTmux.Ref.t(), [split_option()]) ::
          LibTmux.Action.result(String.t())
  def split!(connection, ref, options \\ []),
    do: connection |> split(ref, options) |> LibTmux.Action.unwrap()

  @doc """
  Sends 0..1020 literal bytes to an exact pane, without interpreting key names.

  Hex-key encoding preserves NUL and invalid UTF-8. Empty input sends nothing.
  The terminal's line discipline, active mode and application still determine
  how input is handled; acknowledgement does not prove program consumption.
  Options and outcomes follow `LibTmux.Action`. For named keys use `send_keys/4`.

      Pane.send_text(control, pane_ref, "printf 'hello'")
  """
  @spec send_text(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Action.option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def send_text(connection, ref, bytes, options \\ []),
    do: LibTmux.Action.run(:send_text, connection, ref, bytes, options)

  @doc "Sends bytes as in `send_text/4`, raising API errors while preserving canonical failed outcomes."
  @spec send_text!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Action.option()
        ]) :: LibTmux.Action.result(:ok)
  def send_text!(connection, ref, bytes, options \\ []),
    do: connection |> send_text(ref, bytes, options) |> LibTmux.Action.unwrap()

  @doc """
  Sends 1..128 named keys to an exact pane; unknown names are rejected.

  Supports Enter, Space, Tab, BTab, BSpace, Escape, arrows, Home, End, PageUp,
  PageDown, Insert, Delete and F1..F12. Distinct C-, M- and S- modifiers may
  prefix arrows, Home/End, PageUp/PageDown, Insert/Delete and F1..F12. Also
  accepts C-a..C-z, conventional ASCII control punctuation, and M- plus one
  printable ASCII character. Unsupported combinations such as S-a and C-Enter
  fail before admission; tmux could otherwise type their spelling as text.
  Options and outcomes follow `LibTmux.Action`.

      Pane.send_keys(control, pane_ref, ["Enter", "C-c"])
  """
  @spec send_keys(LibTmux.Action.connection(), LibTmux.Ref.t(), [String.t()], [
          LibTmux.Action.option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def send_keys(connection, ref, keys, options \\ []),
    do: LibTmux.Action.run(:send_keys, connection, ref, keys, options)

  @doc "Sends keys as in `send_keys/4`, raising API errors while preserving canonical failed outcomes."
  @spec send_keys!(LibTmux.Action.connection(), LibTmux.Ref.t(), [String.t()], [
          LibTmux.Action.option()
        ]) :: LibTmux.Action.result(:ok)
  def send_keys!(connection, ref, keys, options \\ []),
    do: connection |> send_keys(ref, keys, options) |> LibTmux.Action.unwrap()

  @doc """
  Captures bounded screen bytes through explicit one-shot execution.

  Returns bytes as `value` after acknowledged completion and native retirement.
  Defaults: visible lines 0 through `:last`, no line joining, 65536 stdout
  bytes, 65536 stderr bytes and 5000ms. `:last` is accepted only for `end_line`.
  Negative line numbers include history;
  tmux clamps the requested range to available lines. Output overflow is an
  error, never a successful partial screen. This observes rendered screen
  state, not the program's original output stream.

  A Control argument returns `unsupported_transport`: arbitrary screen bytes
  are not qualified for shared control framing. No fallback occurs.

      Pane.capture(server, pane_ref, start_line: -100, max_bytes: 131_072)
  """
  @spec capture(LibTmux.Action.connection(), LibTmux.Ref.t(), [capture_option()]) ::
          {:ok, LibTmux.Action.result(binary())} | {:error, LibTmux.Error.t()}
  def capture(connection, ref, options \\ []),
    do: LibTmux.Action.run(:capture, connection, ref, nil, options)

  @doc "Captures as in `capture/3`, raising API errors while preserving canonical failed outcomes."
  @spec capture!(LibTmux.Action.connection(), LibTmux.Ref.t(), [capture_option()]) ::
          LibTmux.Action.result(binary())
  def capture!(connection, ref, options \\ []),
    do: connection |> capture(ref, options) |> LibTmux.Action.unwrap()
end

defmodule LibTmux.Client do
  @moduledoc "An immutable attached-client observation, keyed by validated client name."
  @enforce_keys [:id, :server_instance]
  defstruct [
    :id,
    :server_instance,
    session_id: :unloaded,
    pid: :unloaded,
    width: :unloaded,
    height: :unloaded,
    control_mode: :unloaded
  ]

  @typedoc "An attached client; a known absent height is distinct from unloaded or unavailable coverage."
  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          session_id: LibTmux.Schema.observed(String.t()),
          pid: LibTmux.Schema.observed(non_neg_integer()),
          width: LibTmux.Schema.observed(non_neg_integer()),
          height: LibTmux.Schema.observed(non_neg_integer() | nil),
          control_mode: LibTmux.Schema.observed(boolean())
        }
end
