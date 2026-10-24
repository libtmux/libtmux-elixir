# Inspect a command that needs recovery

Keep the execution error and inspect its operation before leaving the scope.
This application example retains execution and cleanup evidence for the
caller's next decision. Its scope closes the connection when the callback
finishes, which can affect outstanding work. Run it with the
[owned-server recipe](owned-server.md), substituting
`examples/recover_command.exs` for the managed example.

<!-- example: examples/recover_command.exs -->

```elixir
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
```

<!-- /example -->

Call `inspect_execution/1` immediately after execution in the same callback
and caller, while it still owns recovery.
`inspect_execution/1` keeps failed, skipped and unknown canonical outcomes
intact. A pre-admission error means this request was not written. An
`ExecutionError` means admission occurred; lost context does not establish
what happened to its effects.

Domain actions such as `LibTmux.Window.rename/4` already classify unsuccessful
outcomes as `{:error, %LibTmux.Action.CompletionError{}}`. Inspect that error's
`result` to retain its certainty and transport evidence. Their admitted
`ExecutionError` values need the same operation inspection shown here.
The program above uses `Control.execute/3`, whose canonical outcomes remain
inside `{:ok, result}`. See the [return comparison](mental-model.md#return-conventions).

For retained context, one `Operation.status/1` read captures both wire state
and the current result. The read can already report lost context: `:retained`
describes an earlier inspection. A known command result can still precede
wire retirement. The example preserves the original error and the complete
inspection result in either case.

`{:ok, {:error, evidence}}` means the callback recorded an execution problem
and scoped cleanup succeeded. The outer `:ok` does not make the command
successful. After successful scoped cleanup, its owner and operation tables
are gone; the captured status remains evidence, but an escaped handle is not
a durable recovery channel. For independently retained work, use the
[advanced execution API](advanced-execution.md).

A cleanup failure preserves the whole `Control.ScopeFailure`: its `primary`
contains `{:return, callback_value}` or `{:raise, kind, reason, stacktrace}`,
and `cleanup` holds separate uncertainty. With proven cleanup, callback
exceptions, throws and exits propagate unchanged. The scope's closure is an
explicit application lifecycle choice; a timeout itself does not cancel,
replay or establish that a mutation was unwritten.
