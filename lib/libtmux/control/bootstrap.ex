defmodule LibTmux.Control.Bootstrap do
  @moduledoc false
  alias LibTmux.{Deadline, Error, ProcessIdentity, Ref, Server}

  @enforce_keys [:deadline]
  defstruct [:deadline, :pid, :instance, :nonce, phase: :attach, written: false, replied: false]

  def arguments(%Server{} = server, session) do
    case Ref.new(:session, session, "bootstrap") do
      {:ok, _ref} ->
        [
          "-N",
          "-u",
          "-C",
          "-S",
          server.socket,
          "attach-session",
          "-E",
          "-t",
          session,
          "-f",
          "no-output,ignore-size",
          ";",
          "display-message",
          "-p",
          ~S"#{pid}"
        ]

      {:error, _error} ->
        raise ArgumentError, "control attachment requires an exact session ID"
    end
  end

  def new(%Deadline{} = deadline), do: %__MODULE__{deadline: deadline}

  def identify(%__MODULE__{phase: :identity, pid: pid} = state) do
    with {:ok, instance} <- ProcessIdentity.read(pid), do: bind_identity(state, instance)
  end

  # Call only after the candidate identity read. The nonce is never reused.
  def bind_identity(state, instance, options \\ [])

  def bind_identity(%__MODULE__{phase: :identity} = state, instance, options)
      when is_binary(instance) and byte_size(instance) in 1..256 do
    if Deadline.remaining(state.deadline, options) > 0 do
      nonce = :erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string(16)
      {:ok, %{state | phase: :challenge, instance: instance, nonce: nonce}, nonce}
    else
      rejected(:timeout)
    end
  end

  def event(state, event, options \\ []) do
    if Deadline.remaining(state.deadline, options) > 0,
      do: step(state, event),
      else: rejected(:timeout)
  end

  def identity(%__MODULE__{phase: :verified, instance: instance}), do: {:ok, instance}
  def identity(%__MODULE__{}), do: rejected(:identity_unavailable)

  defp step(_state, {:reply, :error, _guard, _lines}), do: rejected(:command_error)

  defp step(%{phase: :attach} = state, {:reply, :ok, {_, _, 0}, []}),
    do: {:ok, %{state | phase: :pid}, []}

  defp step(%{phase: :pid} = state, {:reply, :ok, {_, _, 0}, [value]}) do
    case Integer.parse(value) do
      {pid, ""} when pid in 1..2_147_483_647 ->
        if Integer.to_string(pid) == value,
          do: {:ok, %{state | phase: :identity, pid: pid}, [{:identity, pid}]},
          else: rejected(:invalid_bootstrap)

      _ ->
        rejected(:invalid_bootstrap)
    end
  end

  defp step(%{phase: :challenge, replied: false} = state, {:reply, :ok, {_, _, 1}, [value]}) do
    if value == state.nonce <> ":" <> Integer.to_string(state.pid),
      do: complete(%{state | replied: true}),
      else: rejected(:invalid_bootstrap)
  end

  defp step(%{phase: :challenge, written: false} = state, :written),
    do: complete(%{state | written: true})

  defp step(state, {:notification, name, _payload})
       when name in [
              :client_detached,
              :client_session_changed,
              :layout_change,
              :pane_mode_changed,
              :session_changed,
              :session_renamed,
              :session_window_changed,
              :sessions_changed,
              :unlinked_window_add,
              :unlinked_window_close,
              :unlinked_window_renamed,
              :window_add,
              :window_close,
              :window_pane_changed,
              :window_renamed
            ],
       do: {:ok, state, []}

  defp step(_state, _event), do: rejected(:invalid_bootstrap)

  defp complete(%{written: true, replied: true} = state),
    do: {:ok, %{state | phase: :verified}, [:activate]}

  defp complete(state), do: {:ok, state, []}
  defp rejected(kind), do: {:error, %Error{kind: kind, phase: :connect, certainty: :no_write}}
end
