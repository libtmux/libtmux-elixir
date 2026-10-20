defmodule LibTmux.Transport.Native.Driver do
  @moduledoc false

  alias LibTmux.Transport.Native

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback command(term(), binary()) :: boolean()
  @callback close(term()) :: :ok

  def open([]) do
    {:ok,
     Port.open({:spawn_executable, Native.executable()}, [:binary, :exit_status, {:packet, 2}])}
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :open_failed}
  end

  def command(port, frame) do
    Port.command(port, frame, [:nosuspend])
  rescue
    ArgumentError -> false
  end

  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
