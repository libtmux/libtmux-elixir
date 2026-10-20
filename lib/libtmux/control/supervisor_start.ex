defmodule LibTmux.Control.SupervisorStart do
  @moduledoc false
  @behaviour Supervisor
  alias LibTmux.Deadline

  def start_link(callback, argument, %Deadline{} = deadline) do
    case Deadline.remaining(deadline) do
      0 ->
        {:error, :timeout}

      remaining ->
        reply = :erlang.alias()
        token = make_ref()

        try do
          # OTP's Supervisor entry uses this callback shape without a timeout.
          # proc_lib still awaits actual Root DOWN after its init timer expires.
          result =
            :gen_server.start_link(
              :supervisor,
              {:self, __MODULE__, {callback, argument, reply, token}},
              timeout: remaining
            )

          receive do
            {^token, root} when is_pid(root) -> flush_startup(root)
          after
            0 -> :ok
          end

          result
        after
          # Expired startup cleanup must not demand-load a reply helper.
          :erlang.unalias(reply)

          receive do
            {^token, _late_reply} -> :ok
          after
            0 -> :ok
          end
        end
    end
  end

  @impl true
  def init({callback, argument, reply, token}) do
    send(reply, {token, self()})
    callback.init(argument)
  end

  # proc_lib's timeout cleanup consumes EXIT/DOWN, not a racing ACK/NACK.
  defp flush_startup(root) do
    receive do
      {kind, ^root, _return} when kind in [:ack, :nack] -> :ok
    after
      0 -> :ok
    end
  end
end
