# Public value and encoding examples

These complete programs exercise the lower-level reference without an
interactive session. They are run from the packed core outside the checkout.
For ordinary tasks, begin with [capture and filter](first-task.md).

## Local graph and filtering

Constructing a graph is useful for importers and pure application logic.
`fields` declares what was loaded; `complete` distinguishes a known-empty
relationship from missing coverage. This example declares one session and
empty window, link, pane and client domains. Its positive and absent matches
show cardinality, native predicates and portable filter round trips.

<!-- example: examples/query_values.exs -->

```elixir
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
```

<!-- /example -->

## Encoding and protocol

The deadline uses explicit local clock samples. References here use synthetic
instance tokens and cannot target a real server. Command/format construction,
field decoding, parsing and JSON validation perform no I/O. The last two
calls execute bounded Linux processes to show that a nonzero process exit
is still a transport result, including with `run!/3`.

<!-- example: examples/encoding_values.exs -->

```elixir
alias LibTmux.{Codec, Command, Control, Deadline, Format, Protocol, Ref, Server, Wire}
alias LibTmux.Control.Request
alias LibTmux.Transport.OneShot

server = Server.new(executable: "/unused/tmux", socket: "/unused/socket")

%{id: Control, type: :supervisor} =
  Control.child_spec(server: server, session: {:existing, "$0"}, lane: :host_qualified)

deadline = Deadline.new(100, now: 10)
75 = Deadline.remaining(deadline, now: 35)
0 = Deadline.remaining(deadline, now: 110)
{:ok, ref} = Ref.new(:pane, "%7", "example-instance")
:ok = Ref.validate(ref, "example-instance")
{:error, %{kind: :stale_target}} = Ref.validate(ref, "another-instance")

command = Command.new("display-message", ["-p", Format.literal(~S"#{pid}")])
["display-message", "-p", _literal] = Command.argv(command)
false = String.contains?(Command.render(command), "\n")
true = String.starts_with?(Format.field("pane_title"), "v1:")
{:ok, "hello\n"} = Codec.decode_field("v1:hello\\012\n", :string, encoding: :escaped_v1)
{:ok, <<0, 255>>} = Codec.decode_output("\\000\\377")

parser = Protocol.new(max_line_bytes: 1024)

{:ok, [{:reply, :ok, {1, 2, 1}, ["v1:hello"]}], parser} =
  Protocol.feed(parser, "%begin 1 2 1\nv1:hello\n%end 1 2 1\n")

:ok = Protocol.finish(parser)
:ok = Request.verify_reply(Request.field("pane_title"), :ok, ["v1:hello"])
:ok = Request.verify_reply(Request.set_user_option("@example", "hello"), :ok, [])
{:ok, %{"name" => "work"} = value} = Wire.decode(~s({"name":"work"}))
{:ok, ^value} = Wire.validate(value)

{:ok, %{stdout: "hello\n", exit_status: 0, cleanup: :retired}} =
  OneShot.run("/bin/echo", ["hello"], max_total_bytes: 6)

%{stdout: "", exit_status: 1, cleanup: :retired} = OneShot.run!("/bin/false", [])
IO.puts(JSON.encode!(%{encoding_values: "ok"}))
```

<!-- /example -->

## Supervised control

Use `LibTmux.Control.child_spec/1` when the connection belongs to an application
supervisor. The [executable supervision recipe](supervised-control.md) shows
an application owner, caller access, replacement handles and explicit recovery
after known retirement. Unknown cleanup leaves the connection unavailable.

`LibTmux.Control.reconnect/2` returns a ready replacement only after the old
epoch is proven retired. A ready handle returns itself. It never replays
operations. `request_close/1` and `Operation.stop/1` only request epoch closure;
`close/2` waits for proof. A scope owns its enclosing supervisor too.

The [advanced program](advanced-execution.md) shows local connection/operation
status, canonical result inspection, close-before-forget and actual supervisor
exit. Control and Operation bang variants raise the same API error and retain
canonical failed/skipped/unknown outcomes as values to inspect. Domain bang
actions require command completion and return the completed value; see
`LibTmux.Action`.
