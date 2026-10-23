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
