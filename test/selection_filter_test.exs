defmodule LibTmux.SelectionFilterTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Error, Filter, Selection, Snapshot}
  alias LibTmux.Test.QueryGraph

  doctest Selection

  test "filtering guide examples provide their own aliases" do
    guide = File.read!(Path.expand("../docs/filtering.md", __DIR__))
    snippets = Regex.scan(~r/```elixir\n(.*?)\n```/s, guide, capture: :all_but_first)
    assert length(snippets) == 2

    [panes, sessions] =
      Enum.map(snippets, fn [source] ->
        {result, _binding} =
          Code.eval_string(source, [snapshot: QueryGraph.snapshot()], file: "docs/filtering.md")

        result
      end)

    assert panes == ["%2"]
    assert Enum.map(sessions, & &1.id) == ["$1"]
  end

  test "materialized selections preserve Enum reduction, suspension and ordinary membership" do
    panes = QueryGraph.snapshot() |> Snapshot.panes()
    assert Enum.map(panes, & &1.id) == ["%0", "%1", "%2"]

    assert Enum.zip(panes, 1..2) |> Enum.map(fn {pane, n} -> {pane.id, n} end) == [
             {"%0", 1},
             {"%1", 2}
           ]

    assert Enum.take(panes, 1) |> Enum.map(& &1.id) == ["%0"]
    assert Enum.count(panes) == Selection.size(panes)
    assert Enum.member?(panes, hd(Enum.to_list(panes)))
    refute Enum.member?(panes, "%0")
    assert Selection.member_id?(panes, "%0")
    refute Selection.member_id?(panes, "%9")
    assert Enum.map(Stream.map(panes, & &1.id), & &1) == Enum.map(panes, & &1.id)
  end

  test "native predicates use Enum truthiness and preserve exceptions and captured context" do
    panes = QueryGraph.snapshot() |> Snapshot.panes()
    result = Selection.filter(panes, fn pane -> if pane.active, do: 0, else: nil end)
    assert Enum.map(result, & &1.id) == ["%0", "%2"]
    assert result.snapshot == panes.snapshot
    assert Selection.size(result) == 2

    assert_raise RuntimeError, "predicate failure", fn ->
      Selection.filter(panes, fn _ -> raise "predicate failure" end)
    end

    assert_raise ArgumentError, fn -> Selection.filter(panes, %{active: true}) end
    assert_raise Error, fn -> Selection.where(panes, fn _ -> true end) end
  end

  test "cardinality is checked instead of selecting an arbitrary physical target" do
    panes = QueryGraph.snapshot() |> Snapshot.panes()
    assert {:ok, %{id: "%0"}} = Selection.one(panes, current_command: "bash")
    assert {:error, %Error{kind: :no_match}} = Selection.one(panes, current_command: "missing")

    assert {:error, %Error{kind: :multiple_matches, details: %{at_least: 2}}} =
             Selection.one(panes, current_command: "nvim")

    assert {:ok, nil} = Selection.one_or_nil(panes, current_command: "missing")
    assert Selection.one_or_nil!(panes, current_command: "missing") == nil

    assert_raise Error, ~r/multiple_matches/, fn ->
      Selection.one!(panes, current_command: "nvim")
    end

    assert Selection.exists?(panes, width: [gte: 120])
    assert Selection.count(panes, current_command: [in: ["nvim", "vim"]]) == 2
  end

  test "typed field operators retain nil, empty Boolean and Unicode semantics" do
    panes = QueryGraph.snapshot() |> Snapshot.panes()

    for {criteria, ids} <- [
          {%{width: %{gt: 80}}, ["%1"]},
          {%{exit_status: %{gt: 0}}, ["%2"]},
          {%{exit_status: nil}, ["%0"]},
          {%{exit_status: %{not_in: [nil, 7]}}, ["%1"]},
          {%{current_path: ""}, ["%0", "%1", "%2"]},
          {%{title: %{starts_with: "α", ends_with: "%2", contains: " "}}, ["%2"]},
          {%{and: []}, ["%0", "%1", "%2"]},
          {%{or: []}, []},
          {%{not: %{active: true}}, ["%1"]}
        ] do
      assert panes |> Selection.where(criteria) |> Enum.map(& &1.id) == ids
    end
  end

  test "relation quantifiers stay correlated and counts follow physical versus membership identity" do
    snapshot = QueryGraph.snapshot()
    sessions = Snapshot.sessions(snapshot)
    correlated = %{panes: %{some: %{active: true, current_command: "nvim"}}}

    separate = %{
      and: [%{panes: %{some: %{active: true}}}, %{panes: %{some: %{current_command: "nvim"}}}]
    }

    assert sessions |> Selection.where(correlated) |> Enum.map(& &1.id) == ["$1"]
    assert sessions |> Selection.where(separate) |> Enum.map(& &1.id) == ["$0", "$1"]

    assert sessions
           |> Selection.where(windows: [count: [equals: 1]], window_links: [count: [equals: 2]])
           |> Enum.map(& &1.id) == ["$1"]

    assert Selection.count(sessions, clients: [every: [id: "absent"]]) == 2
    assert Selection.count(sessions, clients: [none: [id: "absent"]]) == 2
    assert Selection.count(sessions, clients: [some: []]) == 0

    assert snapshot
           |> Snapshot.panes()
           |> Selection.where(window: [is: [name: [starts_with: "api-"]]])
           |> Enum.map(& &1.id) == ["%0", "%1"]

    assert snapshot
           |> Snapshot.panes()
           |> Selection.where(window: [is_not: nil])
           |> Selection.size() == 3
  end

  test "grammar and coverage errors precede enumeration, including empty selections" do
    snapshot = QueryGraph.snapshot()
    empty = snapshot |> Snapshot.panes() |> Selection.filter(fn _ -> false end)

    for criteria <- [
          %{mystery: 1},
          %{width: %{gt: "120"}},
          %{active: %{contains: "yes"}},
          [active: true, active: false],
          %{window: [is: [name: "a", name: "b"]]}
        ] do
      assert_raise Error, fn -> Selection.where(empty, criteria) end
    end

    assert_raise Error, ~r/field_not_loaded/, fn ->
      snapshot |> Snapshot.windows() |> Selection.where(layout: "missing")
    end

    assert {:ok, partial} =
             Snapshot.new(%{window: []},
               server_instance: "partial",
               captured_from: 1,
               captured_until: 2,
               fields: %{window: [:id]}
             )

    assert_raise Error, ~r/relation_not_loaded/, fn ->
      partial |> Snapshot.windows() |> Selection.where(panes: [none: []])
    end

    assert {:ok, unavailable} =
             Snapshot.new(%{window: []},
               server_instance: "unavailable",
               captured_from: 1,
               captured_until: 2,
               fields: %{window: [:id]},
               unavailable: %{window: [:layout]}
             )

    assert_raise Error, ~r/field_unavailable/, fn ->
      unavailable |> Snapshot.windows() |> Selection.where(and: [%{or: []}, %{layout: ""}])
    end
  end

  test "canonical filters normalize keywords and maps without merging quantified clauses" do
    assert {:ok, one} = Filter.new(LibTmux.Pane, active: true, width: [gte: 80])
    assert {:ok, two} = Filter.new(LibTmux.Pane, %{width: %{gte: 80}, active: %{equals: true}})
    assert one == two
    assert {:ok, ^one} = Filter.new(LibTmux.Pane, one)
    bounded = Filter.new!(LibTmux.Pane, %{active: true, dead: false}, max_nodes: 3)
    assert {:ok, ^bounded} = Filter.new(LibTmux.Pane, bounded, max_nodes: 3)
    assert Selection.size(Selection.where(Snapshot.panes(QueryGraph.snapshot()), one)) == 1
  end

  test "a validated filter keeps its constructor budget when applied or encoded" do
    criteria = Enum.reduce(1..20, %{width: %{gt: 80}}, fn _, child -> %{not: child} end)
    filter = Filter.new!(LibTmux.Pane, criteria, max_depth: 32)

    assert QueryGraph.snapshot()
           |> Snapshot.panes()
           |> Selection.where(filter)
           |> Enum.map(& &1.id) == ["%1"]

    assert {:ok, ^filter} = Filter.from_wire(LibTmux.Pane, Filter.to_wire(filter), max_depth: 32)
  end

  test "optional active-window predicates distinguish known absence from unloaded relations" do
    assert QueryGraph.snapshot()
           |> Snapshot.sessions()
           |> Selection.where(active_window: [is: [name: "editor"]])
           |> Enum.map(& &1.id) == ["$1"]

    assert {:ok, snapshot} =
             Snapshot.new(%{session: [%{id: "$7"}], window_link: [], window: []},
               server_instance: "absent",
               captured_from: 1,
               captured_until: 2,
               fields: %{
                 session: [:id],
                 window_link: [:id, :session_id, :window_id, :index, :active],
                 window: [:id, :name]
               },
               complete: [:window_link, :window]
             )

    sessions = Snapshot.sessions(snapshot)
    assert Selection.count(sessions, active_window: [is: nil]) == 1
    assert Selection.count(sessions, active_window: [is_not: nil]) == 0
    assert Selection.count(sessions, active_window: [is: [name: "missing"]]) == 0
    assert Selection.count(sessions, active_window: [is_not: [name: "missing"]]) == 1

    links = [
      %{session_id: "$1", window_id: "@1", index: 2, active: true},
      %{session_id: "$1", window_id: "@1", index: 5, active: true}
    ]

    ambiguous = QueryGraph.snapshot(%{window_link: links})

    assert_raise Error, ~r/ambiguous_relation/, fn ->
      ambiguous |> Snapshot.sessions() |> Selection.where(active_window: [is: nil])
    end

    partial = QueryGraph.snapshot(%{window_link: []})

    assert_raise Error, ~r/relation_not_loaded/, fn ->
      partial |> Snapshot.sessions() |> Selection.where(active_window: [is: nil])
    end
  end
end
