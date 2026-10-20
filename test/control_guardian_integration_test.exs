defmodule LibTmux.ControlGuardianIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Command, Deadline, Format, ProcessIdentity, Protocol, Server}
  alias LibTmux.Control.{Admission, Bootstrap, Guardian, Lifetime}
  alias LibTmux.Test.OwnedTmux
  alias LibTmux.Transport.Native.Protocol, as: NativeProtocol

  @moduletag :integration
  @moduletag reason:
               "Qualifies guardian ownership and fresh incarnation bootstrap on a real control client"

  test "bootstrap binds a fresh incarnation, preserves environment and retires its borrowed client" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket, server_pid: server_pid} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})

    assert {_, 0} =
             OwnedTmux.command(fixture, ["set-environment", "-t", "$0", "DISPLAY", "preserved"])

    assert {_, 0} =
             OwnedTmux.command(fixture, ["set-option", "-s", "@guardian", "é\n%end 1 2 1\n"])

    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    pool = Admission.new(1)
    epoch = make_ref()
    bootstrap_token = make_ref()
    deadline = Deadline.new(800)

    payload =
      NativeProtocol.process(executable, Bootstrap.arguments(server, "$0"), cwd: "/", env: %{})

    guardian =
      start_supervised!(
        {Guardian,
         manager: self(),
         router: self(),
         epoch: epoch,
         lifetime: lifetime,
         generation: generation,
         pool: pool,
         bootstrap: bootstrap_token,
         deadline: deadline,
         payload: payload}
      )

    monitor = Process.monitor(guardian)

    state = %{
      guardian: guardian,
      epoch: epoch,
      bootstrap_token: bootstrap_token,
      bootstrap: Bootstrap.new(deadline),
      parser: Protocol.new(max_frame_bytes: 16_384, max_line_bytes: 16_384, max_events: 128),
      bytes: 0,
      deadline: deadline
    }

    try do
      state = startup(state)
      assert {:ok, identity} = Bootstrap.identity(state.bootstrap)
      assert {:ok, ^identity} = ProcessIdentity.read(server_pid)

      assert {"DISPLAY=preserved\n", 0} =
               OwnedTmux.command(fixture, ["show-environment", "-t", "$0", "DISPLAY"])

      assert {"1\n", 0} =
               OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

      line =
        Command.render(Command.new("display-message", ["-p", Format.field("@guardian")])) <> "\n"

      operation = make_ref()
      operation_deadline = Deadline.new(800)

      assert {:ok, lease} =
               Admission.claim(pool, epoch, self(), operation_deadline, byte_size(line))

      assert :ok = Admission.consume(pool, lease, byte_size(line))
      send(guardian, {:write, self(), epoch, operation, lease, 0, byte_size(line), line})

      {state, [encoded]} =
        result(%{state | deadline: operation_deadline}, operation, lease, false, nil)

      assert {:ok, "é\n%end 1 2 1\n"} =
               LibTmux.Codec.decode_field(encoded <> "\n", :bytes, encoding: :escaped_v1)

      send(guardian, {:wire_retired, self(), epoch, operation, lease})
      assert_receive {:guardian, ^epoch, ^guardian, {:wire_retired, ^operation, ^lease}}
      assert :ok = Admission.release(pool, lease)
      assert state.bytes <= 65_536
    after
      send(guardian, {:close, self(), epoch, :test_close})
      assert_receive {:guardian, ^epoch, ^guardian, {:closing, _error}}
      assert_receive {:guardian, ^epoch, ^guardian, {:retired, %{cleanup: :retired}}}, 800
      assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}
      assert :ok = Lifetime.retired(lifetime, generation)
    end

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    assert {:ok, _identity} = ProcessIdentity.read(server_pid)
  end

  defp startup(state) do
    receive do
      {:guardian, epoch, guardian, {:read_credit, credit}}
      when epoch == state.epoch and guardian == state.guardian ->
        send(guardian, {:read, self(), epoch, credit})
        startup(state)

      {:guardian, epoch, guardian, {:stdout, bytes, credit}}
      when epoch == state.epoch and guardian == state.guardian ->
        state = consume(state, bytes, &bootstrap_event/2)
        send(guardian, {:read, self(), epoch, credit})
        startup(state)

      {:guardian, epoch, guardian, {:bootstrap_written, token}}
      when epoch == state.epoch and guardian == state.guardian and token == state.bootstrap_token ->
        startup(bootstrap_event(state, :written))

      {:guardian, epoch, guardian, :active}
      when epoch == state.epoch and guardian == state.guardian ->
        state

      other ->
        flunk("unexpected bootstrap event: #{inspect(other, limit: 5)}")
    after
      Deadline.remaining(state.deadline) ->
        flunk("control startup exceeded its original deadline")
    end
  end

  defp bootstrap_event(state, event) do
    assert {:ok, bootstrap, actions} = Bootstrap.event(state.bootstrap, event)
    state = %{state | bootstrap: bootstrap}

    Enum.reduce(actions, state, fn
      {:identity, _pid}, state ->
        assert {:ok, bootstrap, nonce} = Bootstrap.identify(state.bootstrap)
        send(state.guardian, {:challenge, self(), state.epoch, state.bootstrap_token, nonce})
        %{state | bootstrap: bootstrap}

      :activate, state ->
        send(state.guardian, {:activate, self(), state.epoch, state.bootstrap_token})
        state
    end)
  end

  defp result(state, _token, _lease, true, lines) when not is_nil(lines), do: {state, lines}

  defp result(state, token, lease, written, lines) do
    receive do
      {:guardian, epoch, guardian, {:written, ^token, ^lease, _count}}
      when epoch == state.epoch and guardian == state.guardian ->
        result(state, token, lease, true, lines)

      {:guardian, epoch, guardian, {:stdout, bytes, credit}}
      when epoch == state.epoch and guardian == state.guardian ->
        state =
          consume(state, bytes, fn state, event ->
            case event do
              {:reply, :ok, {_, _, 1}, reply} ->
                assert not Map.has_key?(state, :lines)
                Map.put(state, :lines, reply)

              {:notification, _kind, _payload} ->
                state

              other ->
                flunk("unexpected reply: #{inspect(other, limit: 5)}")
            end
          end)

        send(guardian, {:read, self(), epoch, credit})
        result(state, token, lease, written, Map.get(state, :lines, lines))

      other ->
        flunk("unexpected command event: #{inspect(other, limit: 5)}")
    after
      Deadline.remaining(state.deadline) ->
        flunk("control command exceeded its original deadline")
    end
  end

  defp consume(state, bytes, reducer) do
    assert state.bytes + byte_size(bytes) <= 65_536
    assert {:ok, events, parser} = Protocol.feed(state.parser, bytes)

    Enum.reduce(
      events,
      %{state | parser: parser, bytes: state.bytes + byte_size(bytes)},
      fn event, state -> reducer.(state, event) end
    )
  end
end
