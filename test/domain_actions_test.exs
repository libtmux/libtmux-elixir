defmodule LibTmux.DomainActionsTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Pane, Ref, Server, Session, Window}
  alias LibTmux.Control.Request

  test "modifier spellings with native literal fallback are rejected before admission" do
    {:ok, pane} = Ref.new(:pane, "%0", "instance")

    for key <- ["S-a", "S-Enter", "C-Enter", "C-#", "C-M-a"] do
      request = Request.action(:send_keys, pane, [key], [])

      assert {:error, %{kind: :invalid_command, certainty: :no_write}} =
               Request.encode(request, "instance")
    end
  end

  test "invalid action data and link identities fail before contacting a server" do
    server = Server.new(executable: "/not-a-tmux", socket: "/not-a-socket")
    {:ok, pane} = Ref.new(:pane, "%0", "test-instance")
    {:ok, link} = Ref.new(:window_link, {"$0", 0, "@0"}, "test-instance")
    {:ok, session} = Ref.new(:session, "$0", "other-instance")

    for result <- [
          Pane.split(server, link),
          Pane.split(server, pane, session: session),
          Pane.split(server, pane, size: {:percent, 0}),
          Pane.send_text(server, pane, String.duplicate("x", 1021)),
          Pane.send_keys(server, pane, ["not-a-key"]),
          Pane.send_keys(server, pane, []),
          Window.rename(server, pane, "wrong kind"),
          Session.rename(server, pane, "wrong kind")
        ] do
      assert {:error, %{certainty: :no_write}} = result
    end

    assert_raise LibTmux.Error, fn -> Pane.send_keys!(server, pane, ["not-a-key"]) end

    {:ok, window} = Ref.new(:window, "@0", "test-instance")

    for result <- [
          Window.rename(server, window, "control\u0085name"),
          Pane.capture(server, pane, start_line: :last)
        ] do
      assert {:error, %{kind: :invalid_command, certainty: :no_write}} = result
    end

    control = %Control{owner: self(), view: make_ref(), lifetime: nil, endpoint: %{}}

    for scope <- [nil, session] do
      request = Request.action(:rename_session, session, "work", session: scope)

      assert {:error, %{kind: :invalid_command, phase: :validation, certainty: :no_write}} =
               Request.encode(request, session.server_instance)

      for connection <- [server, control] do
        assert {:error, %{kind: :invalid_command, phase: :validation, certainty: :no_write}} =
                 Session.rename(connection, session, "work", session: scope)

        error =
          assert_raise LibTmux.Error, fn ->
            Session.rename!(connection, session, "work", session: scope)
          end

        assert %{kind: :invalid_command, phase: :validation, certainty: :no_write} = error
      end
    end
  end

  test "qualified action reply validation rejects malformed IDs and unsolicited output" do
    {:ok, pane} = Ref.new(:pane, "%0", "instance")
    split = Request.action(:split, pane, nil, [])
    assert :ok = Request.verify_reply(split, :ok, ["%12"])

    for lines <- [["%01"], ["%12", "extra"], ["%begin 1 2 1"], []] do
      assert {:error, %{kind: :invalid_reply}} = Request.verify_reply(split, :ok, lines)
    end

    input = Request.action(:send_text, pane, "literal", [])
    assert :ok = Request.verify_reply(input, :ok, [])
    assert {:error, %{kind: :invalid_reply}} = Request.verify_reply(input, :ok, ["extra"])
    assert :ok = Request.verify_reply(input, :error, ["can't find pane: %0"])

    assert {:error, %{kind: :unsupported_transport, certainty: :no_write}} =
             Pane.capture(
               %Control{owner: self(), view: make_ref(), lifetime: nil, endpoint: %{}},
               pane
             )
  end
end
