defmodule LibTmux.ControlCodecIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Codec, Command, Deadline, Format, Protocol}
  alias LibTmux.Test.{NativePeer, OwnedTmux}
  alias LibTmux.Transport.Native.Protocol, as: NativeProtocol

  @moduletag :integration
  @moduletag reason: "Qualifies escaped fields and reply framing over a real owned control client"

  test "one encoded field preserves hostile bytes without injecting control replies" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    value = for(byte <- 1..255, into: "", do: <<byte>>)
    value = value <> "é日本語\n%end 17 2 1\n%begin 17 3 1\n%subscription-changed fake\n"
    assert {_, 0} = OwnedTmux.command(fixture, ["set-option", "-s", "@codec", value])

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

    argv = [
      "-N",
      "-u",
      "-C",
      "-S",
      socket,
      "attach-session",
      "-t",
      "$0",
      "-f",
      "no-output,ignore-size"
    ]

    NativePeer.with_process(executable, argv, fn port ->
      startup = Deadline.new(800)
      assert {:started, _pid} = NativePeer.next(port, startup)
      true = Port.command(port, NativeProtocol.read_frame(:stdout, 8192), [:nosuspend])
      true = Port.command(port, NativeProtocol.read_frame(:stderr, 8192), [:nosuspend])
      parser = Protocol.new(max_frame_bytes: 16_384, max_line_bytes: 16_384, max_events: 128)
      {parser, {:reply, :ok, {_, _, 0}, []}} = reply(port, parser, nil, startup)

      assert {"1\n", 0} =
               OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])

      command = Command.new("display-message", ["-p", Format.field("@codec")])
      line = Command.render(command) <> "\n"
      true = Port.command(port, NativeProtocol.write_frame(7, line), [:nosuspend])

      {_parser, {:reply, :ok, {_, _, 1}, [encoded]}} =
        reply(port, parser, {7, byte_size(line)}, Deadline.new(800))

      assert {:ok, ^value} = Codec.decode_field(encoded <> "\n", :bytes, encoding: :escaped_v1)
    end)

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])
  end

  defp reply(port, parser, write, deadline) do
    collect(port, %{parser: parser, write: write, reply: nil, bytes: 0}, deadline)
  end

  defp collect(_port, %{write: nil, reply: reply, parser: parser}, _deadline)
       when not is_nil(reply),
       do: {parser, reply}

  defp collect(port, state, deadline) do
    case NativePeer.next(port, deadline) do
      {:data, :stdout, bytes} ->
        assert state.bytes + byte_size(bytes) <= 65_536
        assert {:ok, events, parser} = Protocol.feed(state.parser, bytes)
        replies = Enum.filter(events, &match?({:reply, _, _, _}, &1))
        assert length(replies) <= 1
        assert state.reply == nil or replies == []
        result = List.first(replies) || state.reply
        true = Port.command(port, NativeProtocol.read_frame(:stdout, 8192), [:nosuspend])

        collect(
          port,
          %{state | parser: parser, reply: result, bytes: state.bytes + byte_size(bytes)},
          deadline
        )

      {:written, id, count, :ok} ->
        assert {id, count} == state.write
        collect(port, %{state | write: nil}, deadline)

      other ->
        flunk("unexpected native control event: #{inspect(other, limit: 5)}")
    end
  end
end
