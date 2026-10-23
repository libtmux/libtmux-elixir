alias LibTmux.{Filter, Schema, Selection, Session, Snapshot}

{:ok, snapshot} =
  Snapshot.new(%{session: [%{id: "$0", name: "work", attached_count: 2}]},
    server_instance: "example-instance",
    captured_from: 10,
    captured_until: 12,
    complete: Schema.entities(),
    fields: %{
      session: [:id, :name, :attached_count],
      window: [:id],
      window_link: [:id, :session_id, :window_id, :index, :active],
      pane: [:id, :window_id],
      client: [:id, :session_id]
    }
  )

[session] = Snapshot.items(snapshot, Session)
{:ok, ^session} = Snapshot.fetch(snapshot, :session, "$0")
:ok = Snapshot.require_complete!(snapshot, :session)
:ok = Snapshot.require_field!(snapshot, :session, :name)
:ok = Snapshot.require_relation!(snapshot, :session, :panes, ["$0"])
[] = Snapshot.related(snapshot, :session, "$0", :panes)
nil = Snapshot.related(snapshot, :session, "$0", :active_window)

sessions = Snapshot.sessions(snapshot)
^sessions = Selection.new(snapshot, Session)
1 = Selection.size(sessions)
1 = Selection.count(sessions, attached: true)
true = Selection.exists?(sessions, name: "work")
true = Selection.member_id?(sessions, "$0")
{:ok, ^session} = Selection.one(sessions)
^session = Selection.one!(sessions)
{:ok, nil} = Selection.one_or_nil(sessions, name: "missing")
nil = Selection.one_or_nil!(sessions, name: "missing")
["$0"] = sessions |> Selection.where(attached: true) |> Enum.map(& &1.id)
[^session] = sessions |> Selection.filter(&String.starts_with?(&1.name, "wo")) |> Enum.to_list()
0 = Selection.size(Snapshot.windows(snapshot))
0 = Selection.size(Snapshot.window_links(snapshot))
0 = Selection.size(Snapshot.panes(snapshot))
0 = Selection.size(Snapshot.clients(snapshot))

{:ok, filter} = Filter.new(Session, name: [starts_with: "wo"])
^filter = Filter.new!(Session, name: [starts_with: "wo"])
true = Filter.to_predicate(filter, snapshot: snapshot).(session)
wire = Filter.to_wire(filter)
{:ok, ^filter} = Filter.from_wire(Session, wire)
{:ok, ^filter} = Filter.from_json(Session, JSON.encode!(wire))

Session = Schema.module(:session)
:session = Schema.entity(Session)
%{name: metadata} = Schema.fields(:session)
^metadata = Schema.field(:session, :name)
nil = Schema.field(:session, :unknown)
true = :starts_with in Schema.operators(metadata)
%{panes: {:many, :pane}} = Schema.relations(:session)
"activeWindow" = Schema.relation_wire(:active_window)
IO.puts(JSON.encode!(%{query_values: "ok"}))
