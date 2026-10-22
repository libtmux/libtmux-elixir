defmodule LibTmux.ProcessIdentity do
  @moduledoc false
  alias LibTmux.Error

  # This names a Linux process, not the process behind an arbitrary IPC endpoint.
  # Persistent bootstrap binds it with a fresh same-connection challenge afterward.
  def read(pid) when is_integer(pid) and pid in 1..2_147_483_647 do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- byte_size(stat) <= 8192 and byte_size(boot) <= 64,
         true <- String.starts_with?(stat, "#{pid} ("),
         {offset, 1} <- List.last(:binary.matches(stat, ")")),
         fields <- stat |> binary_part(offset + 1, byte_size(stat) - offset - 1) |> String.split(),
         value when is_binary(value) <- Enum.at(fields, 19),
         {ticks, ""} <- Integer.parse(value),
         true <- ticks > 0,
         boot <- String.trim(boot),
         true <- Regex.match?(~r/\A[0-9a-f-]{36}\z/, boot) do
      {:ok, "linux:#{boot}:#{pid}:#{ticks}"}
    else
      _ -> {:error, %Error{kind: :identity_unavailable, phase: :connect, certainty: :no_write}}
    end
  end
end
