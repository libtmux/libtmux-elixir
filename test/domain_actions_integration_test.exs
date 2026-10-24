defmodule LibTmux.DomainActionsIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{
    Codec,
    Command,
    Control,
    Format,
    Pane,
    ProcessIdentity,
    Ref,
    Server,
    Session,
    Window
  }

  alias LibTmux.Control.Births
  alias LibTmux.Test.OwnedTmux
  @moduletag :integration
  @moduletag reason: "Qualifies literal input, exact membership and domain actions on owned tmux"

  for lane <- [:one_shot, :control] do
    @tag lane: lane
    test "rename and split preserve physical targets and session context through #{lane}", %{
      lane: lane
    } do
      fixture = start_supervised!({OwnedTmux, []})
      info = OwnedTmux.info(fixture)
      server = server(info)
      {:ok, instance} = ProcessIdentity.read(info.server_pid)
      pane = ref(:pane, "%0", instance)
      window = ref(:window, "@0", instance)
      session = ref(:session, "$1", instance)

      assert {_, 0} =
               OwnedTmux.command(fixture, ["new-session", "-d", "-s", "second", "/bin/cat", "--"])

      for index <- [7, 8],
          do:
            assert(
              {_, 0} =
                OwnedTmux.command(fixture, ["link-window", "-s", "@0", "-t", "$1:#{index}"])
            )

      assert {_, 0} =
               OwnedTmux.command(fixture, [
                 "set-option",
                 "-w",
                 "-t",
                 "@0",
                 "automatic-rename",
                 "off"
               ])

      assert {_, 0} =
               OwnedTmux.command(fixture, ["resize-window", "-t", "@0", "-x", "100", "-y", "40"])

      assert {:ok, before} = Server.snapshot(server)
      name = ~S"name #{pid} $HOME ; } ' " <> "λ"

      normalized =
        if field(fixture, "$0", "version") in ["3.3", "3.3a", "3.4"],
          do: String.replace(name, "$HOME", "\\$HOME"),
          else: name

      try do
        with_lane(lane, server, fn connection ->
          assert {:ok, %{outcome: :completed, value: :ok, certainty: :acknowledged}} =
                   Window.rename(connection, window, name, session: session)

          assert field(fixture, "$1:@0", "window_name") == normalized
          assert field(fixture, "$0:@0", "window_name") == normalized
          assert before.windows["@0"].name != name

          assert {:ok, %{outcome: :completed, value: :ok}} =
                   Session.rename(connection, session, name)

          assert field(fixture, "$1", "session_name") == normalized

          assert {:ok, %{outcome: :completed, value: created}} =
                   Pane.split(connection, pane,
                     session: session,
                     axis: :horizontal,
                     size: {:percent, 25},
                     command: ["/bin/cat", "--"]
                   )

          assert created != pane.id
          assert field(fixture, "$1:.#{created}", "window_id") == "@0"
          assert field(fixture, created, "pane_width") == "25"

          assert {_, 0} =
                   OwnedTmux.command(fixture, [
                     "set-option",
                     "-t",
                     session.id,
                     "default-command",
                     "exec /bin/cat"
                   ])

          assert %{outcome: :completed, value: empty} =
                   Pane.split!(connection, pane, command: [""], session: session)

          try do
            expected_pid = if field(fixture, "$0", "version") == "3.8", do: "", else: "0"
            assert field(fixture, empty, "pane_pid") == expected_pid
            assert field(fixture, empty, "pane_tty") == ""

            for options <- [[], [command: []]] do
              assert %{outcome: :completed, value: default} =
                       Pane.split!(connection, pane, options ++ [session: session])

              pid = field(fixture, default, "pane_pid") |> String.to_integer()
              assert pid > 0
              assert {:ok, _identity} = ProcessIdentity.read(pid)
              assert field(fixture, default, "pane_start_command") =~ "exec /bin/cat"
            end
          after
            # Empty panes have no usable PID; remove them before process-exit watchers.
            assert {_, 0} = OwnedTmux.command(fixture, ["kill-pane", "-t", empty])
          end

          assert {ids, 0} = OwnedTmux.command(fixture, ["list-panes", "-a", "-F", ~S"#{pane_id}"])
          refute empty in String.split(ids)

          assert {:error, %{kind: :stale_target, certainty: :no_write}} =
                   Pane.split(connection, %{pane | server_instance: "old"})

          assert {:error, %{kind: :stale_target, certainty: :no_write}} =
                   Pane.split(connection, pane, session: %{session | server_instance: "old"})

          for index <- [7, 8],
              do:
                assert(
                  {_, 0} = OwnedTmux.command(fixture, ["unlink-window", "-t", "$1:#{index}"])
                )

          assert %{outcome: :failed, value: nil} = Pane.split!(connection, pane, session: session)

          assert %{outcome: :failed} =
                   Window.rename!(connection, window, "must not rename", session: session)

          assert field(fixture, "$0:@0", "window_name") == normalized

          dead = ref(:pane, created, instance)
          pid = field(fixture, created, "pane_pid") |> String.to_integer()
          watch = OwnedTmux.watch_processes([pid])
          assert {_, 0} = OwnedTmux.command(fixture, ["kill-pane", "-t", created])
          assert :ok = OwnedTmux.await_exit(watch)

          assert {:ok, %{outcome: :failed}} =
                   Pane.send_text(connection, dead, "must not retarget")

          assert {:error, %{kind: :invalid_command, certainty: :no_write}} =
                   Window.rename(connection, window, "bad\n%begin 1 2 1")

          assert field(fixture, "$0:@0", "window_name") == normalized
          if lane == :control, do: assert({:ok, %{phase: :ready}} = Control.status(connection))

          if lane == :one_shot do
            assert {_, 0} =
                     OwnedTmux.command(fixture, [
                       "set-hook",
                       "-g",
                       "after-rename-window",
                       "display-message -p diagnostic"
                     ])

            assert {:error, %{kind: :invalid_reply, certainty: :acknowledged, details: details}} =
                     Window.rename(connection, window, "renamed with hook")

            assert details.stdout == "diagnostic\n"
            assert details.stderr == ""
            assert details.exit_status == 0
            assert details.cleanup == :retired
            assert field(fixture, "$0:@0", "window_name") == "renamed with hook"
          end
        end)
      after
        close_fixture(fixture, info)
      end
    end

    @tag lane: lane
    test "literal bytes and named keys reach a raw pane through #{lane}", %{lane: lane} do
      fixture = start_supervised!({OwnedTmux, []})
      info = OwnedTmux.info(fixture)
      server = server(info)
      {:ok, instance} = ProcessIdentity.read(info.server_pid)
      pane = ref(:pane, "%0", instance)
      path = Path.join(Path.dirname(info.socket), "pane-input")
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener)
      python = System.find_executable("python3")

      program = """
      import os, socket, sys, tty
      tty.setraw(0)
      peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      peer.connect(sys.argv[1])
      peer.sendall(b'R')
      os.write(1, b'%begin 9 8 1\\r\\n%end 9 8 1\\r\\n\\x1b[6n')
      while True:
          data = os.read(0, 4096)
          if not data: break
          peer.sendall(data)
      """

      try do
        with_lane(lane, server, fn connection ->
          assert {:ok, %{outcome: :completed, value: id}} =
                   Pane.split(connection, pane, command: [python, "-c", program, path])

          {:ok, peer} = :socket.accept(listener, 750)
          assert {:ok, "R"} = :socket.recv(peer, 1, 750)
          assert {:ok, "\e[3;1R"} = :socket.recv(peer, 6, 750)
          target = ref(:pane, id, instance)
          assert %{outcome: :completed} = Pane.send_text!(connection, target, "")
          bytes = ~S"Enter C-c #{pid}; $HOME" <> <<92, 0, 255, 9, 10, 13>> <> "λ"
          assert %{outcome: :completed, value: :ok} = Pane.send_text!(connection, target, bytes)
          assert {:ok, ^bytes} = :socket.recv(peer, byte_size(bytes), 750)

          assert %{outcome: :completed} =
                   Pane.send_keys!(connection, target, [
                     "Enter",
                     "C-a",
                     "M-x",
                     "Up",
                     "C-Left",
                     "S-F5"
                   ])

          keys = "\r\x01\ex\e[A\e[1;5D\e[15;2~"
          assert {:ok, ^keys} = :socket.recv(peer, byte_size(keys), 750)
          assert :ok = :socket.close(peer)

          assert {:ok, %{outcome: :completed, value: captured, details: %{cleanup: :retired}}} =
                   Pane.capture(server, target, start_line: 0, end_line: 1)

          assert captured == "%begin 9 8 1\n%end 9 8 1\n"
          assert {:error, %{kind: :resource_limit}} = Pane.capture(server, target, max_bytes: 0)

          if lane == :control,
            do:
              assert({:error, %{kind: :unsupported_transport}} = Pane.capture(connection, target))
        end)
      after
        :socket.close(listener)
        close_fixture(fixture, info)
      end
    end
  end

  defp ref(entity, id, instance) do
    {:ok, ref} = Ref.new(entity, id, instance)
    ref
  end

  defp server(info),
    do:
      Server.new(
        executable: System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux"),
        socket: info.socket,
        cwd: "/",
        env: %{}
      )

  defp field(fixture, target, field) do
    assert {encoded, 0} =
             OwnedTmux.command(
               fixture,
               Command.argv(
                 Command.new("display-message", ["-p", "-t", target, Format.field(field)])
               )
             )

    assert {:ok, value} = Codec.decode_field(encoded, :bytes, encoding: :escaped_v1)
    value
  end

  defp with_lane(:one_shot, server, callback), do: callback.(server)

  defp with_lane(:control, server, callback) do
    assert {:ok, watch} =
             Control.with_connection(
               [server: server, session: {:existing, "$0"}, lane: :host_qualified, timeout: 800],
               fn control ->
                 callback.(control)
                 {:ok, %{roles: %{guardian: guardian}}} = Births.snapshot(control.endpoint.births)
                 state = :sys.get_state(guardian, 500)
                 {:os_pid, helper} = Port.info(state.handle, :os_pid)
                 OwnedTmux.watch_processes([helper, state.child])
               end
             )

    assert :ok = OwnedTmux.await_exit(watch)
  end

  defp close_fixture(fixture, info) do
    assert {text, 0} = OwnedTmux.command(fixture, ["list-panes", "-a", "-F", ~S"#{pane_pid}"])
    pids = text |> String.split() |> Enum.map(&String.to_integer/1)
    watch = OwnedTmux.watch_processes([info.server_pid, info.helper_pid | pids])
    assert {:ok, %{pane_exited: true, clients_exited: true}} = OwnedTmux.close(fixture)
    assert :ok = OwnedTmux.await_exit(watch)
  end
end
