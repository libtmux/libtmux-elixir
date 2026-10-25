defmodule LibTmux.CompilerExamples.Valid do
  alias LibTmux.{Codec, Control, Operation, Pane, Selection, Snapshot}

  def pane_ids(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.panes()
    |> Selection.where(active: true)
    |> Enum.map(fn %Pane{id: id} -> id end)
  end

  def pane_reference_id(%Pane{} = pane) do
    {:ok, ref} = LibTmux.Ref.from_observation(pane)
    ref.id
  end

  def session_window_names(snapshot, session) do
    snapshot |> LibTmux.Session.windows(session) |> Enum.map(& &1.name)
  end

  def created_pane_id(connection, pane) do
    case Pane.split(connection, pane) do
      {:ok, %{value: %{id: id}}} when is_binary(id) -> {:ok, id}
      {:error, %LibTmux.Action.CompletionError{result: result}} -> {:error, result}
      {:error, error} -> {:error, error}
    end
  end

  def created_pane_id!(connection, pane) do
    %{id: id} = Pane.split!(connection, pane)
    id
  end

  def submit(%Control{} = control) do
    case Control.submit(control, LibTmux.Control.Request.field("pid")) do
      {:ok, operation} -> Operation.result(operation)
      {:error, error} -> {:error, error}
    end
  end

  def integer_field(bytes) do
    case Codec.decode_field(bytes, :integer) do
      {:ok, number} when is_integer(number) -> number + 1
      {:error, error} -> {:error, error}
    end
  end
end
