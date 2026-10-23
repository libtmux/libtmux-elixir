defmodule LibTmux.DomainActionsTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Pane, Ref, Server, Session, Window}
  alias LibTmux.Control.Request

  test "action refusals locate invalid inputs and retain bounded reasons" do
    server = Server.new(executable: "/not-a-tmux", socket: "/not-a-socket")
    control = %Control{owner: self(), view: make_ref(), lifetime: nil, endpoint: %{}}
    {:ok, pane} = Ref.new(:pane, "%0", "instance")
    {:ok, window} = Ref.new(:window, "@0", "instance")

    for connection <- [server, control] do
      cases = [
        {Pane.split(connection, pane, size: {:percent, 0}), [:options, :size]},
        {Pane.split(connection, pane, axis: :diagonal), [:options, :axis]},
        {Pane.split(connection, pane, mystery: true), [:options, :mystery]},
        {Pane.split(connection, pane, axis: :horizontal, axis: :vertical), [:options, :axis]},
        {Pane.split(connection, pane, timeout: 0), [:options, :timeout]},
        {Pane.split(connection, pane, before: :yes), [:options, :before]},
        {Pane.split(connection, pane, cwd: 42), [:options, :cwd]},
        {Pane.split(connection, pane, command: ["ok", <<0>>]), [:options, :command, 1]},
        {Pane.split(connection, pane, command: ["ok" | :bad_tail]), [:options, :command]},
        {Pane.split(connection, pane, %{}), [:options]},
        {Window.rename(connection, window, String.duplicate("private", 1024)), [:name]},
        {Pane.send_text(connection, pane, :not_bytes), [:text]},
        {Pane.send_keys(connection, pane, ["Enter", "not-a-key"]), [:keys, 1]},
        {Pane.send_keys(connection, pane, ["Enter" | :bad_tail]), [:keys]}
      ]

      for {result, path} <- cases do
        assert {:error, error} = result
        assert error.kind == :invalid_command
        assert error.phase == :validation
        assert error.certainty == :no_write
        assert error.path == path
        assert %{reason: reason} = error.details
        assert is_binary(reason) and byte_size(reason) in 1..256
        assert :erlang.external_size(error) < 512
        assert Exception.message(error) =~ reason
      end
    end

    for {options, field} <- [
          {[max_bytes: -1], :max_bytes},
          {[start_line: :last], :start_line},
          {[end_line: :first], :end_line},
          {[join_lines: :yes], :join_lines}
        ] do
      assert {:error, %{path: [:options, ^field], details: %{reason: reason}}} =
               Pane.capture(server, pane, options)

      assert is_binary(reason)
    end

    error = assert_raise LibTmux.Error, fn -> Pane.split!(server, pane, size: {:percent, 0}) end
    assert error.path == [:options, :size]
    assert Exception.message(error) =~ "1..99"
  end

  test "qualified encoding preserves action validation diagnostics" do
    {:ok, pane} = Ref.new(:pane, "%0", "instance")
    request = Request.action(:split, pane, nil, size: {:percent, 0})

    assert {:error,
            %{kind: :invalid_command, path: [:options, :size], details: %{reason: reason}}} =
             Request.encode(request, "instance")

    assert reason =~ "1..99"

    oversized = Request.action(:split, pane, nil, command: [String.duplicate("x", 16_384)])

    assert {:error,
            %{kind: :invalid_command, path: [:command], details: %{reason: reason}} = error} =
             Request.encode(oversized, "instance")

    assert reason =~ "max_bytes"
    assert :erlang.external_size(error) < 512
  end

  test "one-shot argv growth is rejected before server identity I/O" do
    server = Server.new(executable: "/not-a-tmux", socket: "/not-a-socket")
    {:ok, pane} = Ref.new(:pane, "%0", "instance")
    # The raw command fits 65,536 bytes; escaping the final semicolon adds one.
    argument = String.duplicate("x", 65_489) <> ";"

    assert {:error,
            %{
              kind: :invalid_command,
              phase: :validation,
              certainty: :no_write,
              path: [:command],
              details: %{reason: reason}
            }} = Pane.split(server, pane, command: [argument])

    assert reason =~ "max_bytes"
  end

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

      assert {:error, %{kind: :invalid_command, phase: :validation, certainty: :no_write} = error} =
               Request.encode(request, session.server_instance)

      assert error.path == [:options, :session]
      assert error.details == %{reason: "unknown option for this action"}

      for connection <- [server, control] do
        assert {:error,
                %{kind: :invalid_command, phase: :validation, certainty: :no_write} = error} =
                 Session.rename(connection, session, "work", session: scope)

        assert error.path == [:options, :session]
        assert error.details == %{reason: "unknown option for this action"}

        error =
          assert_raise LibTmux.Error, fn ->
            Session.rename!(connection, session, "work", session: scope)
          end

        assert %{kind: :invalid_command, phase: :validation, certainty: :no_write} = error
        assert error.path == [:options, :session]
        assert error.details == %{reason: "unknown option for this action"}
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
