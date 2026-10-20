defmodule LibTmux.Control.EpochHost do
  @moduledoc false
  use Supervisor

  def start_link(view), do: Supervisor.start_link(__MODULE__, view)

  @impl true
  def init(view) do
    :ets.insert(view, {:host, self()})
    Supervisor.init([], strategy: :one_for_one)
  end
end
