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

  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          name: String.t() | :unloaded | :unavailable,
          attached_count: non_neg_integer() | :unloaded | :unavailable,
          attached: boolean() | :unloaded | :unavailable
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

  @type t :: %__MODULE__{id: String.t(), server_instance: String.t()}
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

  @type t :: %__MODULE__{
          id: {String.t(), non_neg_integer(), String.t()},
          server_instance: String.t()
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

  @type t :: %__MODULE__{
          id: String.t(),
          server_instance: String.t(),
          window_id: String.t() | :unloaded | :unavailable,
          exit_status: non_neg_integer() | nil | :unloaded | :unavailable
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

  @type t :: %__MODULE__{id: String.t(), server_instance: String.t()}
end
