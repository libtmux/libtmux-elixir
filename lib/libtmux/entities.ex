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
  Returns a selection of captured physical windows in first-link order.

  Repeated links to a window contribute it once. For membership indexes use
  `LibTmux.Snapshot.related/4` with `:window_links`.

  The supplied snapshot owns all returned fields and relationships. Only the
  session's ID and incarnation are used; its other fields may be older.
  Invalid or stale identities and missing source/relationship coverage raise
  `LibTmux.Error`. A covered empty relation returns an empty selection.
  No I/O occurs. The selection retains the supplied snapshot for filtering;
  relationship predicates still validate their whole captured source domain.
  Use `Enum.to_list/1` when only the list is needed.

  ## Examples

      iex> alias LibTmux.{Selection, Session, Snapshot}
      iex> rows = %{session: [%{id: "$0"}], window: [%{id: "@7"}],
      ...>   window_link: [%{session_id: "$0", window_id: "@7", index: 0, active: true},
      ...>     %{session_id: "$0", window_id: "@7", index: 3, active: false}],
      ...>   pane: [%{id: "%9", window_id: "@7"}]}
      iex> {:ok, snapshot} = Snapshot.new(rows,
      ...>   server_instance: "example", captured_from: 0, captured_until: 0,
      ...>   complete: [:window_link, :pane],
      ...>   fields: %{window_link: [:session_id, :window_id, :active], pane: [:window_id]})
      iex> {:ok, session} = Snapshot.fetch(snapshot, :session, "$0")
      iex> {:ok, window} = Session.windows(snapshot, session) |> Selection.one()
      iex> window.id
      "@7"
      iex> Session.panes(snapshot, session) |> Enum.map(& &1.id)
      ["%9"]
      iex> Session.active_window(snapshot, session) == window
      true
  """
  @spec windows(LibTmux.Snapshot.t(), t()) :: LibTmux.Selection.t(LibTmux.Window.t())
  def windows(snapshot, session),
    do: LibTmux.Snapshot.related_observation(snapshot, :session, session, :windows)

  @doc """
  Returns a selection of captured physical panes in numeric pane-ID order.

  Linked windows contribute their panes once. Identity, coverage, empty-selection
  and no-I/O behavior follow `windows/2`, which includes a worked example.
  """
  @spec panes(LibTmux.Snapshot.t(), t()) :: LibTmux.Selection.t(LibTmux.Pane.t())
  def panes(snapshot, session),
    do: LibTmux.Snapshot.related_observation(snapshot, :session, session, :panes)

  @doc """
  Returns the captured active physical window, or `nil` when none is active.

  Multiple active links raise `LibTmux.Error`, even when they name the same
  window. Unrelated sessions do not affect this lookup. Identity, coverage
  and no-I/O behavior follow `windows/2`, which includes a worked example.
  """
  @spec active_window(LibTmux.Snapshot.t(), t()) :: LibTmux.Window.t() | nil
  def active_window(snapshot, session),
    do: LibTmux.Snapshot.related_observation(snapshot, :session, session, :active_window)

  @doc """
  Renames an exact session; returns `{:ok, result}` on command completion.

  Names contain 1..1024 UTF-8 bytes without Unicode control characters (Cc).
  Format syntax remains literal;
  tmux still normalizes names (including dollar/backslash escaping, and dots
  and colons on older releases). The only option is `timeout`, which defaults
  to 5000ms.
  Old observations stay unchanged. See `LibTmux.Action` for outcome semantics.

      alias LibTmux.Session

      Session.rename(server, session_ref, "work")
  """
  @spec rename(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Control.call_option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def rename(connection, ref, name, options \\ []),
    do: LibTmux.Action.run(:rename_session, connection, ref, name, options)

  @doc "Returns `:ok` when `rename/4` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec rename!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Control.call_option()
        ]) :: :ok
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
  Returns a selection of captured physical panes in numeric pane-ID order.

  Uses the supplied snapshot and validates the window's ID and incarnation.
  Identity, coverage, empty-selection and no-I/O behavior follow
  `LibTmux.Session.windows/2`.

  ## Examples

      iex> alias LibTmux.{Selection, Snapshot, Window}
      iex> rows = %{window: [%{id: "@0"}], pane: [
      ...>   %{id: "%10", window_id: "@0"}, %{id: "%2", window_id: "@0"}]}
      iex> {:ok, snapshot} = Snapshot.new(rows,
      ...>   server_instance: "example", captured_from: 0, captured_until: 0,
      ...>   complete: [:pane], fields: %{pane: [:id, :window_id]})
      iex> {:ok, window} = Snapshot.fetch(snapshot, :window, "@0")
      iex> Window.panes(snapshot, window) |> Enum.map(& &1.id)
      ["%2", "%10"]
      iex> {:ok, pane} = Window.panes(snapshot, window)
      ...> |> Selection.where(id: "%2") |> Selection.one()
      iex> pane.id
      "%2"
  """
  @spec panes(LibTmux.Snapshot.t(), t()) :: LibTmux.Selection.t(LibTmux.Pane.t())
  def panes(snapshot, window),
    do: LibTmux.Snapshot.related_observation(snapshot, :window, window, :panes)

  @doc """
  Renames an exact physical window across all its memberships.

  Returns `{:ok, result}` on command completion; unsuccessful outcomes return
  `{:error, %LibTmux.Action.CompletionError{}}` with their original evidence.

  Names contain 1..1024 UTF-8 bytes without Unicode control characters (Cc),
  with literal format syntax.
  tmux still applies name normalization, including dollar/backslash escaping.
  Control characters fail before I/O on both transports. Optional `session: session_ref` requires
  membership in that exact session; it does not select a captured link index.
  `timeout` defaults to 5000ms. See `LibTmux.Action` for transport and outcomes.

      alias LibTmux.Window

      Window.rename(control, window_ref, "editor")
  """
  @spec rename(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [LibTmux.Action.option()]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def rename(connection, ref, name, options \\ []),
    do: LibTmux.Action.run(:rename_window, connection, ref, name, options)

  @doc "Returns `:ok` when `rename/4` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec rename!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [LibTmux.Action.option()]) ::
          :ok
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

  @typedoc """
  A physical pane; PID and exit status can be known absent, with separate coverage sentinels.

  `pid` is `nil` when tmux reports no PID. A reported PID or its absence does
  not establish process liveness or cleanup.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          window_id: LibTmux.Schema.observed(String.t()),
          index: LibTmux.Schema.observed(non_neg_integer()),
          active: LibTmux.Schema.observed(boolean()),
          dead: LibTmux.Schema.observed(boolean()),
          width: LibTmux.Schema.observed(non_neg_integer()),
          height: LibTmux.Schema.observed(non_neg_integer()),
          pid: LibTmux.Schema.observed(non_neg_integer() | nil),
          current_command: LibTmux.Schema.observed(String.t()),
          current_path: LibTmux.Schema.observed(String.t()),
          title: LibTmux.Schema.observed(String.t()),
          exit_status: LibTmux.Schema.observed(non_neg_integer() | nil)
        }

  @typedoc "A created pane ID; `ref` is bound for qualified control and `nil` for one-shot."
  @type split_value :: %{id: String.t(), ref: LibTmux.Ref.t() | nil}

  @typedoc "Split geometry and process arguments."
  @type split_option ::
          LibTmux.Action.option()
          | {:axis, :horizontal | :vertical}
          | {:size, {:cells, 1..32_767} | {:percent, 1..99}}
          | {:before | :detached, boolean()}
          | {:cwd, binary()}
          | {:command,
             :default
             | :empty
             | {:shell, binary()}
             | {:argv, nonempty_list(binary())}}
  @typedoc "Bounded one-shot screen capture; line numbers are relative to the visible screen, with negative history offsets."
  @type capture_option ::
          LibTmux.Action.option()
          | {:start_line, -32_768..32_767}
          | {:end_line, -32_768..32_767 | :last}
          | {:join_lines, boolean()}
          | {:max_bytes, 0..1_048_576}

  @doc """
  Splits an exact pane and returns its ID and optional bound reference as `value`.

  A completed value contains `id` and `ref`. Qualified control binds the reference.
  Use it for another action without recapturing. It identifies the pane in
  that server incarnation, contains no fresh fields and does not reserve its
  lifetime. Closing the connection does not invalidate the reference while
  the pane and server remain. One-shot execution does not establish this
  binding and returns `ref: nil`. Unsuccessful outcomes return
  `{:error, %LibTmux.Action.CompletionError{}}` with the original result.

  Defaults: vertical split, half size, detached, after the target, and tmux's
  session default shell/command and directory. `axis: :horizontal` places panes
  side by side; `size: {:percent, n}` uses `-l n%` on every supported release.
  Optional `cwd` is literal format text. Choose `command: :default`, `:empty`,
  `{:shell, nonempty_bytes}` or `{:argv, [program | arguments]}`. Shell text
  uses the session's configured shell; argv uses `execvp` semantics, including
  PATH lookup and executable-text fallback. Empty argv/program and empty
  explicit shell text are rejected. At most 64 argv entries and the existing
  command byte bounds apply; bytes must be NUL-free.

  Singleton argv uses the packaged helper to preserve exactly one argument.
  It replaces itself with the pane program. tmux retains the helper path in
  `pane_start_command`; commandless respawn requires that installation to
  remain available. See [command forms](one-shot-actions.html#command-forms).
  Split acknowledgement does not prove program startup or completion.

  `session: session_ref` selects exact membership/context, not a WindowLink
  index. `timeout` defaults to 5000ms. No snapshot is changed; capture again
  when a new observation is needed. See `LibTmux.Action` for outcomes and the
  one-shot identity check/use limitation.

      alias LibTmux.Pane

      {:ok, %{value: %{ref: created}}} =
        Pane.split(control, pane_ref, axis: :horizontal, size: {:percent, 30})
      Pane.send_text(control, created, "hello")
  """
  @spec split(LibTmux.Action.connection(), LibTmux.Ref.t(), [split_option()]) ::
          {:ok, LibTmux.Action.result(split_value())} | {:error, LibTmux.Action.error()}
  def split(connection, ref, options \\ []),
    do: LibTmux.Action.run(:split, connection, ref, nil, options)

  @doc "Returns the created pane value when `split/3` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec split!(LibTmux.Action.connection(), LibTmux.Ref.t(), [split_option()]) ::
          split_value()
  def split!(connection, ref, options \\ []),
    do: connection |> split(ref, options) |> LibTmux.Action.unwrap()

  @doc """
  Sends 0..995 literal bytes to an exact pane, without interpreting key names.

  Hex-key encoding preserves NUL and invalid UTF-8. Empty input sends nothing.
  Both transports use the same limit, fitting tmux 3.8's command argument
  ceiling. Larger inputs fail validation before I/O; calls are never split.
  The terminal's line discipline, active mode and application still determine
  how input is handled; acknowledgement does not prove program consumption.
  Options and outcomes follow `LibTmux.Action`. For named keys use `send_keys/4`.

      alias LibTmux.Pane

      Pane.send_text(control, pane_ref, "printf 'hello'")
  """
  @spec send_text(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Action.option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def send_text(connection, ref, bytes, options \\ []),
    do: LibTmux.Action.run(:send_text, connection, ref, bytes, options)

  @doc "Returns `:ok` when `send_text/4` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec send_text!(LibTmux.Action.connection(), LibTmux.Ref.t(), binary(), [
          LibTmux.Action.option()
        ]) :: :ok
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

      alias LibTmux.Pane

      Pane.send_keys(control, pane_ref, ["Enter", "C-c"])
  """
  @spec send_keys(LibTmux.Action.connection(), LibTmux.Ref.t(), [String.t()], [
          LibTmux.Action.option()
        ]) ::
          {:ok, LibTmux.Action.result(:ok)} | {:error, LibTmux.Action.error()}
  def send_keys(connection, ref, keys, options \\ []),
    do: LibTmux.Action.run(:send_keys, connection, ref, keys, options)

  @doc "Returns `:ok` when `send_keys/4` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec send_keys!(LibTmux.Action.connection(), LibTmux.Ref.t(), [String.t()], [
          LibTmux.Action.option()
        ]) :: :ok
  def send_keys!(connection, ref, keys, options \\ []),
    do: connection |> send_keys(ref, keys, options) |> LibTmux.Action.unwrap()

  @doc """
  Captures bounded screen bytes through explicit one-shot execution.

  Returns `{:ok, result}` with bytes as `value` after acknowledged completion
  and native retirement. Failed commands return
  `{:error, %LibTmux.Action.CompletionError{}}` with their original evidence.
  Defaults: visible lines 0 through `:last`, no line joining, 65536 stdout
  bytes, 65536 stderr bytes and 5000ms. `:last` is accepted only for `end_line`.
  Negative line numbers include history;
  tmux clamps the requested range to available lines. Output overflow is an
  error, never a successful partial screen. This observes rendered screen
  state, not the program's original output stream.

  A Control argument returns `unsupported_transport`: arbitrary screen bytes
  are not qualified for shared control framing. No fallback occurs.

      alias LibTmux.Pane

      Pane.capture(server, pane_ref, start_line: -100, max_bytes: 131_072)
  """
  @spec capture(LibTmux.Action.connection(), LibTmux.Ref.t(), [capture_option()]) ::
          {:ok, LibTmux.Action.result(binary())}
          | {:error, LibTmux.Error.t() | LibTmux.Action.CompletionError.t()}
  def capture(connection, ref, options \\ []),
    do: LibTmux.Action.run(:capture, connection, ref, nil, options)

  @doc "Returns screen bytes when `capture/3` completes; raises API errors or `LibTmux.Action.CompletionError` otherwise."
  @spec capture!(LibTmux.Action.connection(), LibTmux.Ref.t(), [capture_option()]) ::
          binary()
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
