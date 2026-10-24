defmodule LibTmux.FilterWireTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Error, Filter, Selection, Snapshot, Wire}

  test "versioned wire filters preserve canonical meaning through built-in JSON" do
    panes = LibTmux.Test.QueryGraph.snapshot() |> Snapshot.panes()

    for criteria <- [
          [],
          [active: true],
          %{or: [%{width: %{gte: 120}}, %{window: %{is: %{name: "editor"}}}]},
          %{exit_status: %{in: [nil, 0]}},
          %{and: [%{and: [%{active: true}, %{dead: false}]}, %{width: 80}]}
        ] do
      filter = Filter.new!(LibTmux.Pane, criteria)
      wire = Filter.to_wire(filter)
      assert wire["version"] == 1
      assert wire["entity"] == "pane"
      assert {:ok, decoded} = Filter.from_json(LibTmux.Pane, JSON.encode!(wire))
      assert decoded == filter

      assert Enum.map(Selection.where(panes, decoded), & &1.id) ==
               Enum.map(Selection.where(panes, filter), & &1.id)
    end
  end

  test "unknown keys, duplicate JSON keys, trailing JSON and wrong versions fail with paths" do
    assert {:error, %Error{path: ["where", "currentCommand", "surprise"]}} =
             Filter.from_wire(LibTmux.Pane, %{
               "version" => 1,
               "entity" => "pane",
               "where" => %{"currentCommand" => %{"surprise" => "x"}}
             })

    assert {:error, %Error{path: ["where", "active"]}} =
             Filter.from_json(
               LibTmux.Pane,
               ~S({"version":1,"entity":"pane","where":{"active":true,"active":false}})
             )

    assert {:error, %Error{}} =
             Filter.from_json(LibTmux.Pane, ~S({"version":1,"entity":"pane","where":{}} {}))

    assert {:error, %Error{path: ["version"]}} =
             Filter.from_wire(LibTmux.Pane, %{"version" => 2, "entity" => "pane", "where" => %{}})

    assert {:error, %Error{path: ["entity"]}} =
             Filter.from_wire(LibTmux.Window, %{
               "version" => 1,
               "entity" => "pane",
               "where" => %{}
             })
  end

  test "external input has finite byte, depth, node and list budgets" do
    base = %{"version" => 1, "entity" => "pane", "where" => %{}}

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_json(LibTmux.Pane, JSON.encode!(base), max_bytes: 8)

    deep = Enum.reduce(1..20, %{}, fn _, child -> %{"NOT" => child} end)

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_json(LibTmux.Pane, JSON.encode!(%{base | "where" => deep}), max_depth: 8)

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_wire(
               LibTmux.Pane,
               %{base | "where" => %{"id" => %{"in" => ["%0", "%1", "%2"]}}},
               max_list: 2
             )

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_wire(
               LibTmux.Pane,
               %{base | "where" => %{"AND" => [%{"active" => true}, %{"dead" => false}]}},
               max_nodes: 2
             )
  end

  test "wire validation retains Boolean array indexes in invalid operand paths" do
    payload = %{
      "version" => 1,
      "entity" => "pane",
      "where" => %{"AND" => [%{"active" => true}, %{"width" => %{"gt" => "wide"}}]}
    }

    assert {:error, %Error{path: ["where", "AND", 1, "width", "gt"]}} =
             Filter.from_wire(LibTmux.Pane, payload)

    payload = %{payload | "where" => %{"width" => %{"in" => [80, "bad"]}}}

    assert {:error, %Error{path: ["where", "width", "in", 1]}} =
             Filter.from_wire(LibTmux.Pane, payload)

    payload = %{
      "version" => 1,
      "entity" => "window",
      "where" => %{"panes" => %{"count" => %{"in" => [1, "bad"]}}}
    }

    assert {:error, %Error{path: ["where", "panes", "count", "in", 1]}} =
             Filter.from_wire(LibTmux.Window, payload)
  end

  test "improper external arrays return bounded errors at the array path" do
    for {value, path} <- [{[1 | 2], []}, {%{"items" => [[1 | 2]]}, ["items", 0]}] do
      assert {:error,
              %Error{
                kind: :invalid_json,
                phase: :parse,
                certainty: :no_write,
                path: ^path,
                details: %{code: :improper_list}
              }} = Wire.validate(value)
    end

    payload = %{
      "version" => 1,
      "entity" => "pane",
      "where" => %{"id" => %{"in" => ["%0" | :tail]}}
    }

    assert {:error, %Error{path: ["where", "id", "in"], details: %{code: :improper_list}}} =
             Filter.from_wire(LibTmux.Pane, payload)
  end

  test "array limits reject excess prefixes before walking children" do
    assert {:ok, [1, 2]} = Wire.validate([1, 2], max_list: 2, max_bytes: 5, max_nodes: 3)

    for value <- [[self(), 2, 3], [1, 2, 3 | :tail]] do
      assert {:error, %Error{kind: :resource_limit, path: [], details: %{code: :list}}} =
               Wire.validate(value, max_list: 2)
    end

    assert {:error, %Error{details: %{code: :improper_list}}} =
             Wire.validate([1, 2 | :tail], max_list: 2)

    assert {:error, %Error{details: %{code: :bytes}}} = Wire.validate([1, 2], max_bytes: 4)

    assert {:error, %Error{path: [1], details: %{code: :nodes}}} =
             Wire.validate([1, 2], max_nodes: 2)
  end

  test "decoded maps and JSON use the same inclusive depth boundary" do
    payload = %{"version" => 1, "entity" => "pane", "where" => %{"NOT" => %{}}}
    assert {:ok, filter} = Filter.from_wire(LibTmux.Pane, payload, max_depth: 2)
    assert {:ok, ^filter} = Filter.from_json(LibTmux.Pane, JSON.encode!(payload), max_depth: 2)

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_wire(LibTmux.Pane, payload, max_depth: 1)

    assert {:error, %Error{kind: :resource_limit}} =
             Filter.from_json(LibTmux.Pane, JSON.encode!(payload), max_depth: 1)
  end

  test "a finite Boolean and relational corpus preserves normalization and wire meaning" do
    snapshot = LibTmux.Test.QueryGraph.snapshot()

    for left <- [%{}, %{active: true}, %{width: %{gte: 80}}],
        right <- [%{exit_status: %{in: [nil, 0]}}, %{window: %{is: %{name: "editor"}}}],
        op <- [:and, :or],
        criteria <- [%{op => [left, right]}, %{not: %{op => [left, right]}}] do
      filter = Filter.new!(LibTmux.Pane, criteria)
      assert {:ok, ^filter} = Filter.new(LibTmux.Pane, filter)
      assert {:ok, ^filter} = Filter.from_json(LibTmux.Pane, JSON.encode!(Filter.to_wire(filter)))

      assert Enum.to_list(Selection.where(Snapshot.panes(snapshot), filter)) ==
               Enum.to_list(Selection.where(Snapshot.panes(snapshot), criteria))
    end

    links = Snapshot.window_links(snapshot)

    for criteria <- [%{id: {"$1", 2, "@1"}}, %{id: %{in: [{"$1", 2, "@1"}, {"$1", 5, "@1"}]}}] do
      filter = Filter.new!(LibTmux.WindowLink, criteria)

      assert {:ok, ^filter} =
               Filter.from_json(LibTmux.WindowLink, JSON.encode!(Filter.to_wire(filter)))

      assert Selection.count(links, filter) in [1, 2]
    end

    for criteria <- [
          %{active_window: %{is: nil}},
          %{panes: %{count: %{gte: 2}}},
          %{
            and: [
              %{panes: %{some: %{active: true}}},
              %{panes: %{some: %{current_command: "nvim"}}}
            ]
          }
        ] do
      filter = Filter.new!(LibTmux.Session, criteria)

      assert {:ok, ^filter} =
               Filter.from_json(LibTmux.Session, JSON.encode!(Filter.to_wire(filter)))
    end
  end

  test "composite link IDs obey the index field domain before wire encoding" do
    assert {:error, %Error{details: %{code: :invalid_value}}} =
             Filter.new(LibTmux.WindowLink, %{id: {"$1", 9_223_372_036_854_775_808, "@1"}})

    assert {:error, %Error{details: %{code: :invalid_value}}} =
             Filter.new(LibTmux.WindowLink, %{id: {"$1", 2_147_483_648, "@1"}})

    filter = Filter.new!(LibTmux.WindowLink, %{id: {"$1", 2_147_483_647, "@1"}})

    assert {:ok, ^filter} =
             Filter.from_json(LibTmux.WindowLink, JSON.encode!(Filter.to_wire(filter)))
  end
end
