defmodule LibTmux.Test.QueryGraph do
  @moduledoc false

  def snapshot(overrides \\ %{}) do
    rows = %{
      session: [
        %{id: "$0", name: "main", attached_count: 2},
        %{id: "$1", name: "other", attached_count: 0}
      ],
      window: [
        %{id: "@0", name: "api-main", width: 120, height: 40},
        %{id: "@1", name: "editor", width: 80, height: 24}
      ],
      window_link: [
        %{session_id: "$0", index: 0, window_id: "@0", active: true},
        %{session_id: "$1", index: 2, window_id: "@1", active: true},
        %{session_id: "$1", index: 5, window_id: "@1", active: false}
      ],
      pane: [
        pane("%0", "@0", true, 9, "bash", nil),
        pane("%1", "@0", false, 120, "nvim", 0),
        pane("%2", "@1", true, 80, "nvim", 7)
      ],
      client: []
    }

    rows = Map.merge(rows, overrides)

    fields =
      Map.new(rows, fn {entity, items} ->
        {entity,
         if(entity == :client,
           do: [:id, :session_id],
           else: Enum.uniq([:id | Enum.flat_map(items, &Map.keys/1)])
         )}
      end)

    {:ok, snapshot} =
      LibTmux.Snapshot.new(rows,
        server_instance: "query-fixture",
        captured_from: 1,
        captured_until: 2,
        fields: fields,
        complete: LibTmux.Schema.entities()
      )

    snapshot
  end

  defp pane(id, window, active, width, command, status) do
    %{
      id: id,
      window_id: window,
      active: active,
      dead: false,
      width: width,
      height: 24,
      current_command: command,
      current_path: "",
      title: "α #{id}",
      exit_status: status
    }
  end
end
