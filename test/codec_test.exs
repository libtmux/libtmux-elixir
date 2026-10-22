defmodule LibTmux.CodecTest do
  use ExUnit.Case, async: true

  alias LibTmux.Codec

  test "a free-form response removes exactly its framing newline" do
    assert {:ok, "title\n\t\x1F\x1E\r"} = Codec.decode_field("title\n\t\x1F\x1E\r\n", :string)
    assert {:ok, ""} = Codec.decode_field("\n", :string)
    assert {:error, %{kind: :codec_error}} = Codec.decode_field("unfinished", :string)
  end

  test "invalid UTF-8 stays bytes or fails explicit text decoding" do
    assert {:ok, <<255>>} = Codec.decode_field(<<255, 10>>, :bytes)
    assert {:error, %{kind: :invalid_encoding}} = Codec.decode_field(<<255, 10>>, :string)
  end

  test "escaped field responses require their marker and decode exactly once" do
    assert {:ok, "\\012\n$HOME"} =
             Codec.decode_field("v1:" <> ~S"\134012\012\044HOME" <> "\n", :string,
               encoding: :escaped_v1
             )

    assert {:error, %{kind: :invalid_encoding}} =
             Codec.decode_field("v1:line\nline\n", :bytes, encoding: :escaped_v1)

    assert {:error, %{kind: :codec_error}} =
             Codec.decode_field("wrong:abc\n", :bytes, encoding: :escaped_v1)
  end

  test "scalar decoding consumes the whole value and enforces its range" do
    assert {:ok, 120} = Codec.decode_field("120\n", :integer, min: 0, max: 1000)
    assert {:ok, false} = Codec.decode_field("0\n", :boolean)
    assert {:ok, true} = Codec.decode_field("1\n", :boolean)
    assert {:error, _} = Codec.decode_field("120oops\n", :integer)
    assert {:error, _} = Codec.decode_field("-1\n", :integer, min: 0)
    assert {:error, _} = Codec.decode_field("1001\n", :integer, max: 1000)
    assert {:error, _} = Codec.decode_field("2\n", :boolean)
    assert {:error, %{kind: :resource_limit}} = Codec.decode_field("1234\n", :bytes, max_bytes: 3)
  end

  test "output octal escapes produce bytes without shell evaluation" do
    assert {:ok, <<"a", 27, "[31m", 92, 10, 255>>} =
             Codec.decode_output(~S"a\033[31m\134\012" <> <<255>>)

    for value <- [~S"\12", ~S"\400", ~S"\q", "\\"] do
      assert {:error, %{kind: :invalid_encoding}} = Codec.decode_output(value)
    end
  end
end
