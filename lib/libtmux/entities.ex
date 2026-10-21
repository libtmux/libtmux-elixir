defmodule LibTmux.Session do
  @moduledoc "An immutable session observation. Attachment retains tmux's client count."
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
end

defmodule LibTmux.Window do
  @moduledoc "An immutable physical window, independent of session membership and index."
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
  @moduledoc "An immutable physical pane. It belongs to a window; text may be empty."
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
