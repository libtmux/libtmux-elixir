defmodule LibTmux.SnapshotTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Error, Schema, Selection, Snapshot}

  test "reported pane PID absence remains distinct from zero and malformed values" do
    rows = %{pane: [%{id: "%0", pid: nil}, %{id: "%1", pid: 0}, %{id: "%2", pid: 42}]}
    options = metadata(fields: %{pane: [:id, :pid]})
    assert {:ok, snapshot} = Snapshot.new(rows, options)
    panes = Snapshot.panes(snapshot)
    assert Enum.map(Selection.where(panes, pid: nil), & &1.id) == ["%0"]
    assert Enum.map(Selection.where(panes, pid: 0), & &1.id) == ["%1"]
    assert Enum.map(Selection.where(panes, pid: [gt: 0]), & &1.id) == ["%2"]

    for pid <- ["", "42", -1] do
      assert {:error, %Error{kind: :invalid_field, path: [:pane, "%0", :pid]}} =
               Snapshot.new(%{pane: [%{id: "%0", pid: pid}]}, options)
    end
  end

  test "linked rows retain memberships while physical objects have numeric identity order" do
    rows = graph()
    assert {:ok, snapshot} = build(rows)
    assert Enum.map(Snapshot.items(snapshot, :pane), & &1.id) == ["%2", "%10"]
    assert map_size(snapshot.windows) == 1
    assert map_size(snapshot.window_links) == 3

    assert Enum.map(Snapshot.related(snapshot, :session, "$2", :window_links), & &1.index) == [
             0,
             5
           ]

    assert Enum.map(Snapshot.related(snapshot, :session, "$2", :panes), & &1.id) == ["%2", "%10"]

    assert Enum.map(Snapshot.related(snapshot, :window, "@4", :sessions), & &1.id) == [
             "$2",
             "$10"
           ]

    assert Enum.map(Snapshot.items(snapshot, :client), & &1.id) == ["client-a", "client-z"]
    assert snapshot.sessions["$2"].attached_count == 2
    assert snapshot.sessions["$2"].attached
    assert snapshot.panes["%2"].server_instance == "fixture-instance"
  end

  test "conflicting repeated physical rows and occupied link indexes fail explicitly" do
    rows = graph()
    conflicting = Map.update!(rows, :pane, &[%{id: "%2", window_id: "@4", width: 9} | &1])
    assert {:error, %Error{kind: :conflicting_rows, path: [:pane, "%2"]}} = build(conflicting)

    conflicting =
      Map.update!(rows, :window_link, &[%{session_id: "$2", window_id: "@9", index: 0} | &1])

    assert {:error, %Error{kind: :conflicting_link}} = build(conflicting)
  end

  test "complete graphs reject missing references and invalid field representations" do
    assert {:error, %Error{kind: :inconsistent_snapshot}} = build(%{graph() | window: []})
    rows = Map.update!(graph(), :pane, &[%{id: "%3", window_id: "@4", width: "120"} | &1])
    assert {:error, %Error{kind: :invalid_field, path: [:pane, "%3", :width]}} = build(rows)
  end

  test "coverage separates incomplete, unavailable, empty and known absent data" do
    rows = %{pane: [%{id: "%2", window_id: "@4", current_path: "", exit_status: nil}]}
    fields = %{pane: [:id, :window_id, :current_path, :exit_status]}
    assert {:ok, snapshot} = Snapshot.new(rows, metadata(fields: fields))
    assert snapshot.panes["%2"].current_path == ""
    assert snapshot.panes["%2"].exit_status == nil
    assert snapshot.panes["%2"].width == :unloaded

    assert_raise Error, ~r/relation_not_loaded/, fn ->
      Snapshot.related(snapshot, :pane, "%2", :window)
    end

    assert {:ok, empty} = Snapshot.new(%{pane: []}, metadata(fields: %{pane: [:id]}))

    assert_raise Error, ~r/field_not_loaded/, fn ->
      Snapshot.require_field!(empty, :pane, :width)
    end

    assert_raise Error, ~r/relation_not_loaded/, fn ->
      Snapshot.require_relation!(empty, :window, :panes)
    end

    assert {:ok, unavailable} =
             Snapshot.new(%{pane: []}, metadata(unavailable: %{pane: [:title]}))

    assert_raise Error, ~r/field_unavailable/, fn ->
      Snapshot.require_field!(unavailable, :pane, :title)
    end

    assert {:ok, unavailable} =
             Snapshot.new(rows, metadata(fields: fields, unavailable: %{pane: [:title]}))

    assert unavailable.panes["%2"].title == :unavailable

    assert {:error, %Error{kind: :invalid_field}} =
             Snapshot.new(rows, metadata(unavailable: %{pane: [:mystery]}))

    assert {:ok, unavailable} =
             Snapshot.new(
               %{session: [%{id: "$2"}]},
               metadata(unavailable: %{session: [:attached_count]})
             )

    assert unavailable.sessions["$2"].attached == :unavailable

    assert_raise Error, ~r/field_unavailable/, fn ->
      Snapshot.require_field!(unavailable, :session, :attached)
    end

    assert {:error, %Error{kind: :inconsistent_coverage}} =
             Snapshot.new(
               %{},
               metadata(
                 fields: %{session: [:attached]},
                 unavailable: %{session: [:attached_count]}
               )
             )

    assert {:error, %Error{kind: :inconsistent_coverage}} =
             Snapshot.new(rows, metadata(unavailable: %{pane: [:id]}))
  end

  test "relationship coverage is proved for known empty sets and stays scoped" do
    rows = %{window: [%{id: "@4"}], pane: []}
    fields = %{window: [:id], pane: [:id, :window_id]}
    assert {:ok, snapshot} = Snapshot.new(rows, metadata(fields: fields, complete: [:pane]))
    assert Snapshot.related(snapshot, :window, "@4", :panes) == []

    assert_raise Error, ~r/entity_not_loaded/, fn ->
      Snapshot.require_complete!(snapshot, :window)
    end
  end

  test "direct relation lookup isolates ambiguity while whole-domain validation retains it" do
    rows =
      Map.update!(graph(), :window_link, fn links ->
        [%{session_id: "$10", window_id: "@4", index: 8, active: true} | links]
      end)

    assert {:ok, snapshot} = build(rows)
    assert %{id: "@4"} = Snapshot.related(snapshot, :session, "$2", :active_window)

    for lookup <- [
          fn -> Snapshot.related(snapshot, :session, "$10", :active_window) end,
          fn -> Snapshot.require_relation!(snapshot, :session, :active_window) end,
          fn ->
            snapshot
            |> Snapshot.sessions()
            |> LibTmux.Selection.filter(fn _ -> false end)
            |> LibTmux.Selection.where(active_window: [is: nil])
          end
        ] do
      error = assert_raise Error, lookup
      assert error.kind == :ambiguous_relation
      assert error.path == [:session, "$10", :active_window]
    end

    error =
      assert_raise Error, fn ->
        Snapshot.related(snapshot, :session, "$99", :active_window)
      end

    assert error.kind == :relation_not_loaded
    assert error.path == [:session, :active_window]
  end

  test "session panes preserve numeric order across physical windows and repeated links" do
    rows =
      graph()
      |> Map.update!(:window, &[%{id: "@1", name: "other"} | &1])
      |> Map.update!(:pane, fn panes ->
        [%{id: "%1", window_id: "@1", width: 120} | panes]
      end)
      |> Map.update!(:window_link, fn links ->
        [%{session_id: "$2", window_id: "@1", index: 9, active: false} | links]
      end)

    assert {:ok, snapshot} = build(rows)

    assert Enum.map(Snapshot.related(snapshot, :session, "$2", :panes), & &1.id) == [
             "%1",
             "%2",
             "%10"
           ]
  end

  test "schema rejects unknown fields and native IDs before graph construction" do
    assert Schema.field(:pane, :current_command).wire == "currentCommand"
    assert {:error, %Error{kind: :invalid_field}} = build(%{pane: [%{id: "%2", mystery: 1}]})
    assert {:error, %Error{kind: :invalid_target}} = build(%{pane: [%{id: "%02"}]})
    forged = %{window_link: [%{id: {"$9", 0, "@4"}, session_id: "$2", index: 0, window_id: "@4"}]}
    assert {:error, %Error{kind: :invalid_target}} = build(forged)
  end

  defp metadata(options) do
    Keyword.merge(
      [server_instance: "fixture-instance", captured_from: 10, captured_until: 20],
      options
    )
  end

  defp build(rows) do
    fields =
      Map.new(rows, fn {entity, items} ->
        names = items |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
        {entity, Enum.uniq([:id | names])}
      end)

    Snapshot.new(rows, metadata(fields: fields, complete: Schema.entities()))
  end

  defp graph do
    pane = %{id: "%2", window_id: "@4", width: 120}

    %{
      session: [
        %{id: "$10", name: "second", attached_count: 0},
        %{id: "$2", name: "main", attached_count: 2}
      ],
      window: [%{id: "@4", name: "editor"}],
      window_link: [
        %{session_id: "$2", window_id: "@4", index: 5, active: false},
        %{session_id: "$10", window_id: "@4", index: 7, active: true},
        %{session_id: "$2", window_id: "@4", index: 0, active: true}
      ],
      pane: [%{id: "%10", window_id: "@4", width: 80}, pane, pane],
      client: [%{id: "client-z", session_id: "$10"}, %{id: "client-a", session_id: "$2"}]
    }
  end
end
