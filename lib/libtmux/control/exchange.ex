defmodule LibTmux.Control.Exchange do
  @moduledoc false
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Inbox
  alias LibTmux.Transport.Reply

  def call(inbox, epoch, deadline, request) do
    case Inbox.publish(inbox, epoch, deadline, request) do
      {:ok, ticket} ->
        try do
          monitor = Process.monitor(inbox.owner)

          try do
            with :ok <- Inbox.notify(inbox), do: wait(inbox, ticket, monitor, deadline)
          after
            Process.demonitor(monitor, [:flush])
          end
        after
          try do
            Inbox.close(inbox, ticket)
          after
            Reply.close(ticket.reply, ticket.token)
          end
        end

      error ->
        error
    end
  end

  defp wait(inbox, ticket, monitor, deadline) do
    case Inbox.result(inbox, ticket) do
      :pending ->
        token = ticket.token
        owner = inbox.owner

        receive do
          {^token, :ready} -> read(inbox, ticket, :invalid_reply)
          {:DOWN, ^monitor, :process, ^owner, _reason} -> read(inbox, ticket, :connection_lost)
        after
          Deadline.remaining(deadline) -> read(inbox, ticket, :timeout)
        end

      {:ok, outcome} ->
        outcome

      error ->
        error
    end
  end

  # A completed row is authoritative even when its hint or caller was delayed.
  defp read(inbox, ticket, pending_kind) do
    case Inbox.result(inbox, ticket) do
      {:ok, outcome} -> outcome
      :pending -> {:error, %Error{kind: pending_kind, phase: :wait, certainty: :unknown}}
      error -> error
    end
  end
end
