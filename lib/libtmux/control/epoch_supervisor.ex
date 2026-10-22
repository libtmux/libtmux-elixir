defmodule LibTmux.Control.EpochSupervisor do
  @moduledoc false
  use Supervisor
  alias LibTmux.Control.Births

  def start_link(births), do: Supervisor.start_link(__MODULE__, births)

  def child_spec(births) do
    %{
      id: :epoch,
      start: {__MODULE__, :start_link, [births]},
      restart: :temporary,
      type: :supervisor,
      shutdown: 950
    }
  end

  @impl true
  def init(births) do
    case Births.register(births, :epoch_supervisor) do
      :ok -> Supervisor.init([], strategy: :one_for_one)
      {:error, error} -> exit(error)
    end
  end
end
