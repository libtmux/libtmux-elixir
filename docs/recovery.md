# Inspect a command that needs recovery

Keep the execution error and inspect its operation before leaving the scope.
The example keeps execution and cleanup evidence for the caller's next
decision. Its scope closes the connection when the callback finishes, which
can affect outstanding work. Run it on a private server with the
[owned-server runner](owned-server.md):

```console
$ python3 examples/owned_server.py \
    --run "$(command -v tmux)" \
    mix run examples/recover_command.exs
```

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

- Call `inspect_execution/1` right after execution, in the same callback and
  caller, while it still owns recovery.
- It keeps failed, skipped and unknown canonical outcomes intact.
- A pre-admission error means this request was not written. An
  `ExecutionError` means admission occurred; lost context does not show what
  happened to its effects.
- Domain actions such as `LibTmux.Window.rename/4` already return
  unsuccessful outcomes as `{:error, %LibTmux.Action.CompletionError{}}`.
  Inspect its `result` for certainty and transport evidence. Their admitted
  `ExecutionError` values need the operation inspection shown here.
- The program uses `Control.execute/3`, whose canonical outcomes stay inside
  `{:ok, result}`. See the [return comparison](mental-model.md#return-conventions).

For retained context, one `Operation.status/1` read captures the wire state and
the current result:

- The read can already report lost context; `:retained` describes an earlier
  inspection.
- A known command result can precede wire retirement.
- The example keeps the original error and the whole inspection result either
  way.

After the scope:

- `{:ok, {:error, evidence}}` means the callback recorded an execution problem
  and scoped cleanup succeeded. The outer `:ok` does not make the command
  successful.
- The owner and operation tables are gone. The captured status stays as
  evidence, but an escaped handle is not a durable recovery channel. For
  independently retained work, use the
  [advanced execution API](advanced-execution.md).
- A cleanup failure keeps the whole `Control.ScopeFailure`. Its `primary` holds
  `{:return, callback_value}` or `{:raise, kind, reason, stacktrace}`, and its
  `cleanup` holds the separate uncertainty.
- With proven cleanup, callback exceptions, throws and exits propagate
  unchanged.
- Closing the scope is an explicit lifecycle choice. A timeout does not
  cancel, replay or show that a mutation was unwritten.
