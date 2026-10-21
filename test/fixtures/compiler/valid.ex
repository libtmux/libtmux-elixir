defmodule LibTmux.CompilerExamples.Valid do
  alias LibTmux.{Codec, Control, Operation, Pane, Selection, Snapshot}

  def pane_ids(%Snapshot{} = snapshot) do
    snapshot
    |> Snapshot.panes()
    |> Selection.where(active: true)
    |> Enum.map(fn %Pane{id: id} -> id end)
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
