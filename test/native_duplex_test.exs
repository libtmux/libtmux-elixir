defmodule LibTmux.NativeDuplexTest do
  use ExUnit.Case, async: true
  alias LibTmux.Deadline
  alias LibTmux.Transport.Native
  alias LibTmux.Transport.Native.Protocol

  @moduletag :integration
  @moduletag reason:
               "Qualifies persistent helper input, per-stream credits and terminal retirement evidence"

  test "persistent child writes acknowledge exact byte counts and retain independent read credits" do
    port =
      Port.open({:spawn_executable, Native.executable()}, [:binary, :exit_status, {:packet, 2}])

    try do
      payload = Protocol.process("/bin/cat", [], cwd: "/", env: %{})
      true = Port.command(port, Protocol.open_frame(payload, input: :open, timeout: 0))
      assert_receive {^port, {:data, <<?S, pid::32>>}}, 800
      assert pid > 0
      true = Port.command(port, Protocol.read_frame(:stdout, 8192))
      true = Port.command(port, Protocol.read_frame(:stderr, 8192))
      first = :binary.list_to_bin(Enum.to_list(0..255)) |> :binary.copy(32)
      second = <<"again", 0, 255>>

      for {id, bytes} <- [{7, first}, {8, second}] do
        true = Port.command(port, Protocol.write_frame(id, bytes))
        result = collect_write(port, id, bytes, Deadline.new(800), %{ack: false, output: ""})
        assert result.ack
        assert result.output == bytes
      end

      true = Port.command(port, Protocol.close_frame())
      assert {:retired, 0, 0} = await_terminal(port, Deadline.new(800), false, nil)
    after
      if Port.info(port) do
        true = Port.command(port, Protocol.stop_frame())
        assert {:retired, _reason, _status} = await_terminal(port, Deadline.new(750), false, nil)
      end
    end
  end

  defp collect_write(_port, _id, bytes, _deadline, %{ack: true, output: bytes} = result),
    do: result

  defp collect_write(port, id, expected, deadline, result) do
    receive do
      {^port, {:data, frame}} ->
        case Protocol.decode(frame) do
          {:ok, {:written, ^id, count, :ok}} when count == byte_size(expected) ->
            collect_write(port, id, expected, deadline, %{result | ack: true})

          {:ok, {:data, :stdout, bytes}} ->
            assert byte_size(result.output) + byte_size(bytes) <= byte_size(expected)
            true = Port.command(port, Protocol.read_frame(:stdout, 8192))

            collect_write(port, id, expected, deadline, %{result | output: result.output <> bytes})

          other ->
            flunk("unexpected native event: #{inspect(other)}")
        end
    after
      Deadline.remaining(deadline) -> flunk("native duplex write exceeded its deadline")
    end
  end

  defp await_terminal(port, deadline, evidence, result) do
    receive do
      {^port, {:data, frame}} ->
        case Protocol.decode(frame) do
          {:ok, {:terminal, reason, status}} ->
            true = Port.command(port, Protocol.terminal_ack_frame())
            await_terminal(port, deadline, true, {reason, status})

          {:ok, {:failed, _kind, _errno}} ->
            true = Port.command(port, Protocol.terminal_ack_frame())
            await_terminal(port, deadline, true, {nil, nil})

          _ ->
            await_terminal(port, deadline, evidence, result)
        end

      {^port, {:exit_status, 0}} when evidence ->
        {reason, status} = result
        {:retired, reason, status}

      {^port, {:exit_status, status}} ->
        flunk("native exit without retirement proof: #{status}")
    after
      Deadline.remaining(deadline) -> flunk("native retirement exceeded its deadline")
    end
  end
end
