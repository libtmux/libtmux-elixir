defmodule LibTmux.Transport.Native do
  @moduledoc false

  def executable do
    Path.join([
      :code.priv_dir(:libtmux) |> to_string(),
      "native",
      :erlang.system_info(:system_architecture) |> to_string(),
      "libtmux_io"
    ])
  end

  def encode_string(value), do: <<byte_size(value)::16, value::binary>>
end
