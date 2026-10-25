defmodule LibTmux.Capture do
  @moduledoc """
  Builds a bounded one-shot observation of one existing Linux tmux server.

  Capture checks topology and OS server identity before and after field
  reads. Attempts share the original deadline and work budgets; `attempts`
  defaults to 2 and accepts 1–3. Only inconsistent topology or disappearing
  read targets retry. Decoding and coverage errors remain visible.

  Defaults: 1024 topology rows, 512 commands, 8 MiB total response bytes,
  64 KiB per response and 5000 ms. Exhausted capture-wide budgets return an
  error, never a partial success. Both topology scans count contextual linked rows.
  Free-form fields use one encoded listing per entity kind. One successful
  attempt uses 13 commands when those three listings fit. After a listing
  exceeds the response ceiling and its client retires, capture reads that
  kind's physical entities individually. The failed listing still consumes
  commands, bytes and time. Duplicate linked text rows consume bytes.
  Capture adds no control attachment. Hooks configured on list commands can
  still have effects; retries do not replay application mutations.
  """

  alias LibTmux.{Codec, Command, Deadline, Error, Format, Schema, Server, Snapshot}
  alias LibTmux.Capture.Row

  @typedoc """
  Capture-wide budgets shared by all attempts and reads.

  Each read uses the smaller of remaining `max_bytes` and `max_response_bytes`.
  That effective ceiling must fit OneShot's 16 MiB stdout limit. The shared
  deadline must have at most 600,000 ms remaining when OneShot validates a read.
  Invalid combinations raise `ArgumentError` before that command executes.
  """
  @type option ::
          {:timeout, pos_integer()}
          | {:deadline, Deadline.t()}
          | {:attempts, 1..3}
          | {:max_entities | :max_commands | :max_bytes | :max_response_bytes, pos_integer()}
  @session_fields [:id, :attached_count]
  @window_fields [:width, :height, :zoomed]
  @link_fields [:session_id, :index, :window_id, :active]
  @pane_fields [:id, :window_id, :index, :active, :dead, :width, :height, :pid, :exit_status]
  @client_fields [:id, :session_id, :pid, :width, :height, :control_mode]
  @strings %{
    session: [:name],
    window: [:name, :layout],
    pane: [:current_command, :current_path, :title]
  }

  @doc """
  Performs bounded capture through an explicit server descriptor.

  See `t:option/0` for the composed work, response and remaining-deadline
  constraints inherited from `LibTmux.Transport.OneShot.run/3`.

  See the [worked example](first-task.html).
  """
  @spec fetch(Server.t(), [option()]) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def fetch(%Server{} = server, options \\ []) do
    if Keyword.has_key?(options, :deadline) and Keyword.has_key?(options, :timeout),
      do: raise(ArgumentError, "pass a deadline or timeout, not both")

    deadline =
      Keyword.get_lazy(options, :deadline, fn ->
        Deadline.new(Keyword.get(options, :timeout, 5000))
      end)

    options =
      Keyword.validate!(options, [
        :deadline,
        :timeout,
        attempts: 2,
        max_entities: 1024,
        max_commands: 512,
        max_bytes: 8_388_608,
        max_response_bytes: 65_536
      ])

    unless options[:attempts] in 1..3 and
             Enum.all?([:max_entities, :max_commands, :max_bytes, :max_response_bytes], fn key ->
               is_integer(options[key]) and options[key] > 0
             end),
           do:
             raise(
               ArgumentError,
               "capture budgets must be positive integers; attempts must be 1..3"
             )

    state = %{
      server: server,
      deadline: deadline,
      options: Map.new(options),
      commands: 0,
      bytes: 0,
      rows: 0
    }

    attempt(state, 1)
  end

  defp attempt(state, number) do
    try do
      started = System.monotonic_time(:millisecond)
      {instance, state} = identity(state)
      {before, state} = topology(state)
      {rows, state} = text_fields(before, state)
      {after_rows, state} = topology(state)
      {after_instance, state} = identity(state)

      if instance != after_instance or signature(before) != signature(after_rows),
        do: stop(state, :topology_changed)

      fields =
        Map.new(Schema.entities(), fn entity -> {entity, Map.keys(Schema.fields(entity))} end)

      case Snapshot.new(rows,
             server_instance: instance,
             captured_from: started,
             captured_until: System.monotonic_time(:millisecond),
             fields: fields,
             complete: Schema.entities()
           ) do
        {:ok, snapshot} ->
          if Deadline.remaining(state.deadline) == 0, do: stop(state, :timeout)
          {:ok, snapshot}

        {:error, error} ->
          throw({:capture_error, error, state})
      end
    catch
      {:capture_error, error, state} ->
        if retryable?(error) do
          if number < state.options.attempts and Deadline.remaining(state.deadline) > 0 do
            attempt(state, number + 1)
          else
            {:error,
             %Error{
               kind: :inconsistent_snapshot,
               phase: :capture,
               details: %{
                 attempts: number,
                 last_kind: error.kind,
                 commands: state.commands,
                 bytes: state.bytes
               }
             }}
          end
        else
          {:error, error}
        end
    end
  end

  defp retryable?(%Error{kind: kind})
       when kind in [
              :topology_changed,
              :inconsistent_snapshot,
              :conflicting_rows,
              :conflicting_link
            ],
       do: true

  defp retryable?(%Error{kind: :command_error, details: %{code: :not_found}}), do: true
  defp retryable?(_error), do: false

  defp topology(state) do
    {sessions, state} = list(state, "list-sessions", [], :session, @session_fields)

    formats =
      Enum.map(@link_fields, &format(:window_link, &1)) ++
        Enum.map(@window_fields, &format(:window, &1))

    {windows, state} = rows(state, "list-windows", ["-a"], Enum.join(formats, "\t"))

    {links_and_windows, state} =
      Enum.map_reduce(windows, state, fn line, acc ->
        fields =
          Enum.map(@link_fields, &{:window_link, &1}) ++ Enum.map(@window_fields, &{:window, &1})

        decoded = decode_row(acc, line, fields)
        link = Map.take(decoded, @link_fields)
        window = decoded |> Map.take(@window_fields) |> Map.put(:id, link.window_id)
        {{link, window}, acc}
      end)

    {panes, state} = list(state, "list-panes", ["-a"], :pane, @pane_fields)
    {clients, state} = list(state, "list-clients", [], :client, @client_fields)
    {links, windows} = Enum.unzip(links_and_windows)

    {%{session: sessions, window: windows, window_link: links, pane: panes, client: clients},
     state}
  end

  defp list(state, command, arguments, entity, fields) do
    expression = Enum.map_join(fields, "\t", &format(entity, &1))
    {lines, state} = rows(state, command, arguments, expression)

    {Enum.map(lines, &decode_row(state, &1, Enum.map(fields, fn field -> {entity, field} end))),
     state}
  end

  defp rows(state, command, arguments, expression) do
    {output, state} = read(state, command, arguments ++ ["-F", expression])

    lines =
      case output do
        "" ->
          []

        _ ->
          unless :binary.last(output) == 10, do: stop(state, :codec_error)
          output |> binary_part(0, byte_size(output) - 1) |> :binary.split("\n", [:global])
      end

    state = %{state | rows: state.rows + length(lines)}

    if state.rows > state.options.max_entities,
      do: stop(state, :resource_limit, %{reason: :entity_rows})

    {lines, state}
  end

  defp decode_row(state, line, fields) do
    values = :binary.split(line, "\t", [:global])
    unless length(values) == length(fields), do: stop(state, :codec_error, %{reason: :row_fields})

    Map.new(Enum.zip(fields, values), fn {{entity, field}, value} ->
      metadata = Schema.field(entity, field)
      {field, decode(state, value <> "\n", metadata, entity, field)}
    end)
  end

  defp decode(state, output, metadata, entity, field, encoding \\ :escaped_v1) do
    {type, options} =
      case metadata.type do
        {:id, :client} -> {:string, [encoding: encoding]}
        {:id, _} -> {:string, []}
        :string -> {:string, [encoding: encoding]}
        :nullable_integer -> {:integer, [min: 0, max: 2_147_483_647]}
        :integer -> {:integer, [min: 0, max: 2_147_483_647]}
        :boolean -> {:boolean, []}
      end

    result =
      if metadata.nullable and output == "\n",
        do: {:ok, nil},
        else: Codec.decode_field(output, type, options)

    case result do
      {:ok, value} ->
        unless Schema.valid_value?(metadata, value),
          do: stop(state, :invalid_field, %{entity: entity, field: field})

        value

      {:error, error} ->
        throw({:capture_error, %{error | path: [entity, field]}, state})
    end
  end

  defp format(entity, field) do
    metadata = Schema.field(entity, field)

    if metadata.type == :string or metadata.type == {:id, :client},
      do: Format.field(metadata.format),
      else: ~S"#{" <> metadata.format <> "}"
  end

  defp text_fields(rows, state) do
    Enum.reduce(@strings, {rows, state}, fn {entity, fields}, {rows, state} ->
      {by_id, state} =
        try do
          bulk_text_fields(entity, fields, state)
        catch
          {:capture_error,
           %Error{
             kind: :resource_limit,
             phase: :capture,
             details: %{reason: reason, cleanup: :retired}
           }, state}
          when reason in [:stdout_bytes, :total_bytes] ->
            individual_text_fields(rows[entity], entity, fields, state)
        end

      unless MapSet.new(Map.keys(by_id)) == MapSet.new(rows[entity], & &1.id),
        do: stop(state, :topology_changed)

      rows =
        Map.update!(
          rows,
          entity,
          &Enum.map(&1, fn row -> Map.merge(row, Map.fetch!(by_id, row.id)) end)
        )

      {rows, state}
    end)
  end

  defp bulk_text_fields(entity, fields, state) do
    {command, arguments} =
      case entity do
        :session -> {"list-sessions", []}
        :window -> {"list-windows", ["-a"]}
        :pane -> {"list-panes", ["-a"]}
      end

    expression = Row.format(Enum.map([:id | fields], &Schema.field(entity, &1).format))
    {output, state} = read(state, command, arguments ++ ["-F", expression])
    unless output == "" or :binary.last(output) == 10, do: stop(state, :codec_error)

    lines =
      if output == "",
        do: [],
        else: output |> binary_part(0, byte_size(output) - 1) |> :binary.split("\n", [:global])

    by_id =
      Enum.reduce(lines, %{}, fn line, found ->
        decoded = decode_text_fields(line <> "\n", entity, [:id | fields], state)
        {id, values} = Map.pop!(decoded, :id)
        if Map.has_key?(found, id) and found[id] != values, do: stop(state, :conflicting_rows)
        Map.put(found, id, values)
      end)

    {by_id, state}
  end

  defp individual_text_fields(rows, entity, fields, state) do
    expression = Row.format(Enum.map(fields, &Schema.field(entity, &1).format))

    {values, state} =
      rows
      |> Enum.uniq_by(& &1.id)
      |> Enum.map_reduce(state, fn row, state ->
        {output, state} = read(state, "display-message", ["-p", "-t", row.id, expression])
        {{row.id, decode_text_fields(output, entity, fields, state)}, state}
      end)

    {Map.new(values), state}
  end

  defp decode_text_fields(output, entity, fields, state) do
    case Row.decode(output, length(fields), max_bytes: state.options.max_response_bytes) do
      {:ok, values} ->
        Map.new(Enum.zip(fields, values), fn {field, value} ->
          {field, decode(state, value <> "\n", Schema.field(entity, field), entity, field, :raw)}
        end)

      {:error, error} ->
        path =
          case error.path do
            [index] -> [entity, Enum.at(fields, index)]
            _ -> [entity]
          end

        throw({:capture_error, %{error | path: path}, state})
    end
  end

  defp signature(rows) do
    %{
      sessions: rows.session |> Enum.map(& &1.id) |> MapSet.new(),
      links:
        rows.window_link |> Enum.map(&{&1.session_id, &1.index, &1.window_id}) |> MapSet.new(),
      panes: rows.pane |> Enum.map(&{&1.id, &1.window_id}) |> MapSet.new(),
      clients: rows.client |> Enum.map(&{&1.id, &1.session_id}) |> MapSet.new()
    }
  end

  defp identity(state) do
    {output, state} = read(state, "display-message", ["-p", ~S"#{pid}"])

    case Codec.decode_field(output, :integer, min: 1, max: 2_147_483_647) do
      {:ok, pid} ->
        case LibTmux.ProcessIdentity.read(pid) do
          {:ok, token} -> {token, state}
          {:error, _error} -> stop(state, :identity_unavailable)
        end

      {:error, error} ->
        throw({:capture_error, error, state})
    end
  end

  defp read(state, command, arguments) do
    if state.commands >= state.options.max_commands,
      do: stop(state, :resource_limit, %{reason: :commands})

    remaining = state.options.max_bytes - state.bytes
    if remaining <= 0, do: stop(state, :resource_limit, %{reason: :bytes})
    limit = min(remaining, state.options.max_response_bytes)
    state = %{state | commands: state.commands + 1}

    result =
      Server.run(state.server, Command.new(command, arguments),
        deadline: state.deadline,
        max_stdout_bytes: limit,
        max_stderr_bytes: min(limit, 65_536),
        max_total_bytes: limit
      )

    data =
      case result do
        {:ok, data} -> data
        {:error, error} -> error.details
      end

    state = %{
      state
      | bytes:
          state.bytes + byte_size(Map.get(data, :stdout, "")) +
            byte_size(Map.get(data, :stderr, ""))
    }

    if state.bytes > state.options.max_bytes, do: stop(state, :resource_limit, %{reason: :bytes})

    case result do
      {:ok, result} ->
        {result.stdout, state}

      {:error, error} ->
        throw({:capture_error, error, state})
    end
  end

  defp stop(state, kind, details \\ %{}),
    do:
      throw(
        {:capture_error,
         %Error{
           kind: kind,
           phase: :capture,
           details: Map.merge(%{commands: state.commands, bytes: state.bytes}, details)
         }, state}
      )
end
