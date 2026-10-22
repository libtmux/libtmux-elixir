defmodule LibTmux.Test.NativeDriver do
  @moduledoc false

  def open(options) do
    observer = Keyword.fetch!(options, :observer)
    fault = :atomics.new(1, [])
    handle = {make_ref(), observer, fault}
    send(observer, {:driver_open, self(), handle})
    {:ok, handle}
  end

  def command({_ref, observer, fault} = handle, frame) do
    send(observer, {:driver_command, self(), handle, frame})

    :atomics.get(fault, 1) != 2 and
      not (:atomics.get(fault, 1) == 1 and match?(<<?W, _::binary>>, frame))
  end

  def close({_ref, observer, _fault} = handle) do
    send(observer, {:driver_closed, self(), handle})
    :ok
  end
end
