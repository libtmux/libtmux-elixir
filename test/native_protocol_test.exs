defmodule LibTmux.NativeProtocolTest do
  use ExUnit.Case, async: true
  alias LibTmux.Error
  alias LibTmux.Transport.Native.Protocol

  test "process frames preserve argv and target environment bytes under one packet ceiling" do
    payload =
      Protocol.process("/bin/cat", ["", <<255>>, "literal\nargument"],
        cwd: "/",
        env: %{"EMPTY" => "", "RAW" => <<255>>, "TMUX" => "removed"}
      )

    <<1::16, "/", 4::16, rest::binary>> = payload
    {arguments, rest} = take(rest, 4)
    assert arguments == ["/bin/cat", "", <<255>>, "literal\nargument"]
    <<2::16, rest::binary>> = rest
    assert {environment, ""} = take(rest, 2)
    assert environment == ["EMPTY=", <<"RAW=", 255>>]

    assert <<?O, 3, 1, 0::32, ^payload::binary>> =
             Protocol.open_frame(payload, input: :open, timeout: 0)

    assert <<?O, 3, 0, 25::32, ^payload::binary>> =
             Protocol.open_frame(payload, input: :closed, timeout: 25)

    assert_raise ArgumentError, fn ->
      Protocol.process("/bin/cat", [String.duplicate("x", 32_000)],
        cwd: "/",
        env: %{"PAD" => String.duplicate("y", 1000)}
      )
    end

    for {executable, arguments, options} <- [
          {"cat", [], [cwd: "/", env: %{}]},
          {"/bin/cat", [<<0>>], [cwd: "/", env: %{}]},
          {"/bin/cat", [], [cwd: "/", env: %{"BAD=KEY" => "x"}]}
        ],
        do:
          assert_raise(ArgumentError, fn -> Protocol.process(executable, arguments, options) end)
  end

  test "argv capacity includes the executable without increasing environment capacity" do
    environment = Map.new(1..256, &{"KEY#{&1}", ""})
    payload = Protocol.process("/bin/true", List.duplicate("", 2047), cwd: "/", env: environment)
    assert <<1::16, "/", 2048::16, _::binary>> = payload

    assert_raise ArgumentError, fn ->
      Protocol.process("/bin/true", List.duplicate("", 2048), cwd: "/", env: %{})
    end

    assert_raise ArgumentError, fn ->
      Protocol.process("/bin/true", [], cwd: "/", env: Map.put(environment, "EXTRA", ""))
    end
  end

  test "duplex command frames bound each grant and acknowledged write fragment" do
    assert Protocol.read_frame(:stdout, 8192) == <<?R, 1, 8192::16>>
    assert Protocol.read_frame(:stderr, 1) == <<?R, 2, 1::16>>
    assert Protocol.write_frame(7, <<0, 255>>) == <<?W, 7::32, 0, 255>>
    assert Protocol.close_frame() == "C"
    assert Protocol.stop_frame() == "Q"
    assert Protocol.terminal_ack_frame() == "T"

    for size <- [0, 8193],
        do: assert_raise(ArgumentError, fn -> Protocol.read_frame(:stdout, size) end)

    assert_raise ArgumentError, fn -> Protocol.write_frame(1, "") end
    assert_raise ArgumentError, fn -> Protocol.write_frame(1, String.duplicate("x", 8193)) end
  end

  test "native output distinguishes cleanup evidence, incomplete cleanup and byte acknowledgements" do
    for {frame, event} <- [
          {<<?S, 123::32>>, {:started, 123}},
          {<<?D, 1, 0, 255>>, {:data, :stdout, <<0, 255>>}},
          {<<?Z, 2>>, {:eof, :stderr}},
          {<<?A, 9::32, 4096::16, 1>>, {:written, 9, 4096, :error}},
          {<<?A, 9::32, 8192::16, 0>>, {:written, 9, 8192, :ok}},
          {"C", :input_closed},
          {<<?E, 1, 137::32>>, {:terminal, 1, 137}},
          {<<?F, 2, 2::32>>, {:failed, 2, 2}},
          {<<?F, 4, 0::32>>, {:warning, :cleanup_incomplete}}
        ],
        do: assert(Protocol.decode(frame) == {:ok, event})

    for frame <- [
          "",
          <<?S, 0::32>>,
          <<?D, 1>>,
          <<?D, 3, 0>>,
          <<?D, 1>> <> String.duplicate("x", 8193),
          <<?A, 1::32, 8193::16, 0>>,
          <<?A, 1::32, 3::16, 2>>,
          <<?E, 4, 0::32>>,
          <<?F, 4, 1::32>>
        ],
        do: assert(match?({:error, %Error{kind: :protocol_error}}, Protocol.decode(frame)))
  end

  defp take(rest, 0), do: {[], rest}

  defp take(<<size::16, value::binary-size(size), rest::binary>>, count) do
    {tail, rest} = take(rest, count - 1)
    {[value | tail], rest}
  end
end
