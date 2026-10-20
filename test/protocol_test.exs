defmodule LibTmux.ProtocolTest do
  use ExUnit.Case, async: true

  alias LibTmux.Protocol

  test "chunk boundaries do not change replies or scoped notifications" do
    wire =
      "%session-changed $1 dev\n%begin 17 2 1\né\n%window-add @999\n%end 17 99 1\n%end 17 2 1\n%begin 18 3 1\nmissing\n%error 18 3 1\n"

    expected = [
      {:notification, :session_changed, "$1 dev"},
      {:reply, :ok, {17, 2, 1}, ["é", "%window-add @999", "%end 17 99 1"]},
      {:reply, :error, {18, 3, 1}, ["missing"]}
    ]

    for offset <- 0..byte_size(wire) do
      <<left::binary-size(^offset), right::binary>> = wire
      assert collect([left, right]) == expected
    end

    assert collect(for <<byte <- wire>>, do: <<byte>>) == expected
  end

  test "line, frame, chunk and emitted-event limits are independent" do
    assert {:error, %{kind: :resource_limit}} =
             Protocol.feed(Protocol.new(max_line_bytes: 4), "12345")

    assert {:error, %{kind: :resource_limit}} =
             Protocol.feed(Protocol.new(max_frame_bytes: 4), "%begin 1 1 1\n1234\n")

    assert {:error, %{kind: :resource_limit}} =
             Protocol.feed(Protocol.new(max_chunk_bytes: 4), "12345")

    assert {:error, %{kind: :resource_limit}} =
             Protocol.feed(Protocol.new(max_events: 1), "%exit\n%exit\n")

    assert {:error, %{kind: :resource_limit}} =
             Protocol.feed(Protocol.new(max_frame_lines: 1), "%begin 1 1 1\na\nb\n")

    assert_raise ArgumentError, fn -> Protocol.new(max_events: 0) end
  end

  test "malformed suffixes retain already completed reply evidence" do
    assert {:error, %{kind: :protocol_error, details: details}} =
             Protocol.feed(Protocol.new(), "%begin 1 1 1\n%end 1 1 1\n%begin nope\n")

    assert details.events == [{:reply, :ok, {1, 1, 1}, []}]
  end

  test "end of stream rejects incomplete lines and command blocks" do
    assert {:ok, [], state} = Protocol.feed(Protocol.new(), "%begin 1 1 1\n")
    assert {:error, %{kind: :protocol_error}} = Protocol.finish(state)
    assert {:ok, [], state} = Protocol.feed(Protocol.new(), "%sess")
    assert {:error, %{kind: :protocol_error}} = Protocol.finish(state)
  end

  defp collect(chunks) do
    {events, state} =
      Enum.reduce(chunks, {[], Protocol.new()}, fn chunk, {events, state} ->
        assert {:ok, next, state} = Protocol.feed(state, chunk)
        {events ++ next, state}
      end)

    assert :ok = Protocol.finish(state)
    events
  end
end
