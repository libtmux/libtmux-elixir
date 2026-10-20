defmodule LibTmux.Transport.Reply do
  @moduledoc false

  def close(reply, token) do
    :erlang.unalias(reply)

    receive do
      {^token, _late_reply} -> :ok
    after
      0 -> :ok
    end
  end
end
