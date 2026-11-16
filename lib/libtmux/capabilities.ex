defmodule LibTmux.Capabilities do
  @moduledoc """
  Named tmux primitive requirements on an observed daemon.

  Obtain a report with `LibTmux.Server.capabilities/2` or
  `LibTmux.Control.capabilities/2`. Decisions describe native tmux primitives;
  they do not advertise an implemented Elixir Program API. Unknown releases
  refuse discovery, and unknown feature IDs return an explicit error.

  Reports are captured data. Pure checks perform no I/O and grant no mutation
  authority. Editing a report cannot change the registry or another report.
  A later operation still needs its own identity and capability checks.
  """

  alias LibTmux.{Codec, Command, Control, Deadline, Error, ProcessIdentity, Server}
  alias LibTmux.Control.Request

  @registry_path Path.expand("../../priv/tmux/capabilities.json", __DIR__)
  @support_path Path.expand("../../priv/tmux/support.json", __DIR__)
  @external_resource @registry_path
  @external_resource @support_path
  @registry JSON.decode!(File.read!(@registry_path))
  @minimum JSON.decode!(File.read!(@support_path))["tmux_minimum"]
  @entries Map.new(@registry["features"], &{&1["id"], &1})
  @profiles @registry["profiles"]

  @enforce_keys [:daemon_version, :server_instance, :source, :features]
  defstruct [:daemon_version, :server_instance, :source, :epoch, :features]

  @typedoc "A native primitive decision, independent of whether the library exposes that operation."
  @type decision :: %{
          id: String.t(),
          since: String.t(),
          scope: :tmux_primitive,
          handling: :refuse,
          source: String.t(),
          summary: String.t(),
          commands: [map()],
          state: :supported | :unsupported | :unknown,
          supported: boolean()
        }
  @typedoc "Captured daemon evidence; a one-shot report does not pin the descriptor's future connections."
  @type t :: %__MODULE__{
          daemon_version: String.t(),
          server_instance: String.t(),
          source: :one_shot | :control,
          epoch: reference() | nil,
          features: %{String.t() => decision()}
        }
  @typedoc "One 1..600000ms monotonic observation budget; default 1000ms."
  @type option :: {:timeout, 1..600_000}

  @doc "Returns one registry decision without I/O; unknown IDs return an error."
  @spec status(t(), String.t()) :: {:ok, decision()} | {:error, Error.t()}
  def status(%__MODULE__{daemon_version: version}, id) do
    case Map.fetch(@entries, id) do
      {:ok, entry} -> {:ok, decision(entry, version)}
      :error -> failure(:unknown_feature, :unknown_feature, :no_write)
    end
  end

  @doc "Returns whether the observed release supports one named native primitive."
  @spec supports?(t(), String.t()) :: boolean()
  def supports?(%__MODULE__{} = report, id),
    do: match?({:ok, %{supported: true}}, status(report, id))

  @doc "Returns the supported decision or a no-write refusal, without refreshing daemon evidence."
  @spec require(t(), String.t()) :: {:ok, decision()} | {:error, Error.t()}
  def require(%__MODULE__{} = report, id) do
    case status(report, id) do
      {:ok, %{supported: true} = decision} ->
        {:ok, decision}

      {:ok, decision} ->
        {:error,
         %Error{
           kind: :unsupported_feature,
           phase: :capabilities,
           certainty: :no_write,
           path: [:feature],
           details: %{id: decision.id, required: decision.since, observed: report.daemon_version}
         }}

      error ->
        error
    end
  end

  @doc false
  @spec from_observation(String.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def from_observation(version, %{server_instance: instance, source: source, epoch: epoch})
      when is_binary(instance) and byte_size(instance) in 1..256 and
             source in [:one_shot, :control] do
    with {:ok, _release} <- profile(version) do
      {:ok,
       %__MODULE__{
         daemon_version: version,
         server_instance: instance,
         source: source,
         epoch: epoch,
         features: Map.new(@entries, fn {id, entry} -> {id, decision(entry, version)} end)
       }}
    end
  end

  @doc false
  @spec observe(Server.t() | Control.t(), [option()]) ::
          {:ok, t()} | {:error, Error.t() | LibTmux.Control.ExecutionError.t()}
  def observe(connection, options) do
    options = Keyword.validate!(options, timeout: 1000)
    timeout = options[:timeout]

    unless is_integer(timeout) and timeout in 1..600_000 and
             length(options) == map_size(Map.new(options)),
           do:
             raise(
               ArgumentError,
               "capability timeout must be 1..600000ms without duplicate options"
             )

    observe_deadline(connection, Deadline.new(timeout))
  end

  defp observe_deadline(%Server{} = server, deadline) do
    with {:ok, first} <- probe(server, deadline),
         {:ok, _release} <- profile(first.version),
         {:ok, instance} <- ProcessIdentity.read(first.pid),
         {:ok, second} <- probe(server, deadline),
         {:ok, after_instance} <- ProcessIdentity.read(first.pid) do
      if first == second and instance == after_instance do
        finish(
          first.version,
          %{
            server_instance: instance,
            source: :one_shot,
            epoch: nil
          },
          deadline
        )
      else
        failure(:stale_server, :daemon_changed, :observed)
      end
    end
  end

  defp observe_deadline(%Control{} = control, deadline) do
    with {:ok, before} <- ready(control),
         {:ok, result} <- Control.execute_deadline(control, Request.field("version"), deadline),
         {:ok, version} <- control_version(result),
         {:ok, after_status} <- ready(control) do
      if Map.take(before, [:epoch, :generation, :instance]) ==
           Map.take(after_status, [:epoch, :generation, :instance]) do
        finish(
          version,
          %{
            server_instance: before.instance,
            source: :control,
            epoch: before.epoch
          },
          deadline
        )
      else
        failure(:stale_connection, :epoch_changed, :no_write)
      end
    end
  end

  defp finish(version, context, deadline) do
    if Deadline.remaining(deadline) > 0,
      do: from_observation(version, context),
      else: failure(:timeout, :observation_deadline, :observed)
  end

  defp ready(control) do
    case Control.status(control) do
      {:ok, %{phase: :ready} = status} -> {:ok, status}
      {:ok, _status} -> failure(:stale_connection, :not_ready, :no_write)
      error -> error
    end
  end

  defp control_version(%{outcome: :completed, lines: [field]}) do
    Codec.decode_field(field <> "\n", :bytes, encoding: :escaped_v1)
  end

  defp control_version(result),
    do:
      {:error,
       %Error{
         kind: :capability_observation_failed,
         phase: :capabilities,
         details: %{result: result}
       }}

  defp probe(server, deadline) do
    nonce = :erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string(16)
    marker = "libtmux-cap-#{System.pid()}-#{nonce}-"
    command = Command.new("run-shell", ["-C", marker <> ~S"#{pid}_#{version}."])

    case Server.run(server, command,
           deadline: deadline,
           max_stdout_bytes: 0,
           max_stderr_bytes: 1024,
           max_total_bytes: 1024,
           max_chunks: 16
         ) do
      {:error,
       %Error{
         kind: :command_error,
         details: %{stdout: "", stderr: stderr, exit_status: 1, cleanup: :retired}
       } = original} ->
        case parse_probe(stderr, marker) do
          {:ok, _} = observed ->
            observed

          {:error, error} ->
            {:error, %{error | details: Map.put(error.details, :command_error, original)}}
        end

      {:error, _} = error ->
        error

      {:ok, _} ->
        failure(:invalid_capability_reply, :unexpected_success, :observed)
    end
  end

  defp parse_probe(stderr, marker) do
    prefix = "unknown command: " <> marker

    with true <- String.starts_with?(stderr, prefix),
         rest <- binary_part(stderr, byte_size(prefix), byte_size(stderr) - byte_size(prefix)),
         [_, pid, version] <- Regex.run(~r/\A([1-9][0-9]{0,9})_([a-zA-Z0-9.-]{1,32})\.\n\z/, rest),
         pid <- String.to_integer(pid),
         true <- pid <= 2_147_483_647 do
      {:ok, %{pid: pid, version: version}}
    else
      _ -> failure(:invalid_capability_reply, :malformed_reply, :observed)
    end
  end

  defp decision(entry, version) do
    state =
      with {:ok, actual} <- profile(version),
           {:ok, required} <- release(entry["since"]) do
        if actual >= required, do: :supported, else: :unsupported
      else
        _ -> :unknown
      end

    %{
      id: entry["id"],
      since: entry["since"],
      scope: :tmux_primitive,
      handling: :refuse,
      source: entry["source"],
      summary: entry["summary"],
      commands: entry["commands"],
      state: state,
      supported: state == :supported
    }
  end

  defp profile(version) do
    with {:ok, actual} <- release(version),
         {:ok, minimum} <- release(@minimum),
         true <- actual >= minimum and Map.has_key?(@profiles, version) do
      {:ok, actual}
    else
      _ -> failure(:unsupported_version, :unknown_or_unsupported_profile, :observed)
    end
  end

  defp release(version) when is_binary(version) and byte_size(version) in 1..32 do
    cond do
      match = Regex.run(~r/\A([0-9]+)\.([0-9]+)([a-z]?)\z/, version) ->
        [_, major, minor, letter] = match
        patch = if letter == "", do: 0, else: :binary.first(letter) - ?a + 1
        {:ok, {String.to_integer(major), String.to_integer(minor), 2, 0, patch}}

      match = Regex.run(~r/\A([0-9]+)\.([0-9]+)-rc([0-9]*)\z/, version) ->
        [_, major, minor, candidate] = match
        candidate = if candidate == "", do: 0, else: String.to_integer(candidate)
        {:ok, {String.to_integer(major), String.to_integer(minor), 1, candidate, 0}}

      match = Regex.run(~r/\Anext-([0-9]+)\.([0-9]+)\z/, version) ->
        [_, major, minor] = match
        {:ok, {String.to_integer(major), String.to_integer(minor), 0, 0, 0}}

      true ->
        :error
    end
  end

  defp release(_version), do: :error

  defp failure(kind, reason, certainty),
    do:
      {:error,
       %Error{kind: kind, phase: :capabilities, certainty: certainty, details: %{reason: reason}}}
end
