defmodule CommandRecovery do
  alias LibTmux.{Control, Error, Operation}
  alias LibTmux.Control.{ExecutionError, ScopeFailure}

  def run(options, callback) do
    case Control.with_connection(options, callback) do
      {:ok, callback_value} -> {:ok, callback_value}
      {:error, %ScopeFailure{} = failure} -> {:error, {:cleanup, failure}}
      {:error, %Error{} = error} -> {:error, {:startup, error}}
    end
  end

  def inspect_execution(execution) do
    case execution do
      {:ok, %{outcome: :completed} = result} ->
        {:ok, result}

      {:ok, result} ->
        {:error, {:outcome, result}}

      {:error, %ExecutionError{context: :retained} = error} ->
        {:error, {:execution, error, Operation.status(error.operation)}}

      {:error, %ExecutionError{context: :lost} = error} ->
        {:error, {:execution, error, :lost}}

      {:error, %Error{} = error} ->
        {:error, {:not_admitted, error}}
    end
  end
end

alias LibTmux.{Control, Server}
alias LibTmux.Control.Request

[executable, socket, session_id] = System.argv()
{:ok, _} = Application.ensure_all_started(:libtmux)

server =
  Server.new(
    executable: executable,
    socket: socket,
    env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
  )

result =
  CommandRecovery.run(
    [server: server, session: {:existing, session_id}, lane: :host_qualified],
    fn control ->
      control
      |> Control.execute(Request.set_user_option("@recovery_example", "recorded"))
      |> CommandRecovery.inspect_execution()
    end
  )

case result do
  {:ok, {:ok, _command_result}} ->
    IO.puts(JSON.encode!(%{recovery_example: "completed", connection_retired: true}))

  {:ok, {:error, evidence}} ->
    IO.inspect(:stderr, evidence, label: "command needs attention; connection retired")
    System.halt(1)

  {:error, {:cleanup, failure}} ->
    IO.inspect(:stderr, failure, label: "primary outcome and unproved cleanup")
    System.halt(1)

  {:error, {:startup, error}} ->
    IO.inspect(:stderr, error, label: "connection startup failed")
    System.halt(1)
end
