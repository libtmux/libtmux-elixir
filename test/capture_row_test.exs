defmodule LibTmux.CaptureRowTest do
  use ExUnit.Case, async: true

  alias LibTmux.Capture.Row
  alias LibTmux.Error

  test "versioned rows preserve empty fields, escaped separators and arbitrary bytes" do
    encoded = "r1:3\tv1:\\134\\044\\011\\012\tv1:\tv1:" <> <<255>> <> "\n"
    assert Row.decode(encoded, 3) == {:ok, ["\\$\t\n", "", <<255>>]}
    assert Row.decode("r1:1\tv1:日本語\n", 1) == {:ok, ["日本語"]}
  end

  test "row framing and escapes fail before partial values can escape" do
    for {response, count, kind} <- [
          {"r2:1\tv1:x\n", 1, :codec_error},
          {"r1:2\tv1:x\n", 1, :codec_error},
          {"r1:2\tv1:x\n", 2, :codec_error},
          {"r1:1\tv1:x\tv1:y\n", 1, :codec_error},
          {"r1:1\tv1:x", 1, :codec_error},
          {"r1:1\tx\n", 1, :codec_error},
          {"r1:1\tv1:x\ny\n", 1, :invalid_encoding},
          {"r1:2\tv1:ok\tv1:\\12\n", 2, :invalid_encoding}
        ] do
      assert {:error, %Error{kind: ^kind}} = Row.decode(response, count)
    end

    assert {:error, %Error{kind: :invalid_encoding, path: [1]}} =
             Row.decode("r1:2\tv1:ok\tv1:\\z\n", 2)

    assert {:error, %Error{kind: :resource_limit}} =
             Row.decode("r1:1\tv1:large\n", 1, max_bytes: 12)
  end
end
