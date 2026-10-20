defmodule LibTmux.NativeDuplexTest do
  use ExUnit.Case, async: true
  alias LibTmux.Deadline
  alias LibTmux.Test.NativePeer
  alias LibTmux.Transport.Native.Protocol

  @moduletag :integration
  @moduletag reason:
               "Qualifies persistent helper input, per-stream credits and terminal retirement evidence"

  test "persistent child writes acknowledge exact byte counts and retain independent read credits" do
    NativePeer.with_process("/bin/cat", [], fn port ->
      assert {:started, pid} = NativePeer.next(port, Deadline.new(800))
      assert pid > 0
      true = Port.command(port, Protocol.read_frame(:stdout, 8192), [:nosuspend])
      true = Port.command(port, Protocol.read_frame(:stderr, 8192), [:nosuspend])
      first = :binary.list_to_bin(Enum.to_list(0..255)) |> :binary.copy(32)
      second = <<"again", 0, 255>>

      for {id, bytes} <- [{7, first}, {8, second}] do
        true = Port.command(port, Protocol.write_frame(id, bytes), [:nosuspend])
        result = collect_write(port, id, bytes, Deadline.new(800), %{ack: false, output: ""})
        assert result.ack
        assert result.output == bytes
      end

      true = Port.command(port, Protocol.close_frame(), [:nosuspend])
      assert {:retired, {:terminal, 0, 0}} = NativePeer.await_exit(port, Deadline.new(800))
    end)
  end

  defp collect_write(_port, _id, bytes, _deadline, %{ack: true, output: bytes} = result),
    do: result

  defp collect_write(port, id, expected, deadline, result) do
    case NativePeer.next(port, deadline) do
      {:written, ^id, count, :ok} when count == byte_size(expected) ->
        collect_write(port, id, expected, deadline, %{result | ack: true})

      {:data, :stdout, bytes} ->
        assert byte_size(result.output) + byte_size(bytes) <= byte_size(expected)
        true = Port.command(port, Protocol.read_frame(:stdout, 8192), [:nosuspend])
        collect_write(port, id, expected, deadline, %{result | output: result.output <> bytes})

      other ->
        flunk("unexpected native event: #{inspect(other)}")
    end
  end
end
