defmodule LibTmux.CommandTest do
  use ExUnit.Case, async: true

  alias LibTmux.Command

  test "argv preserves terminal semicolons across tmux's second parser" do
    command = Command.new("set-option", ["-s", "@value", "ends\\;"])
    assert Command.argv(command) == ["set-option", "-s", "@value", "ends\\\\;"]
  end

  test "rendering never places raw input newlines on a control command line" do
    command = Command.new("set-option", ["-s", "@value", "\n;#{inspect(:hostile)}\r"])
    rendered = Command.render(command)
    assert :binary.match(rendered, ["\n", "\r"]) == :nomatch
    assert String.starts_with?(rendered, "set-option ")
  end

  test "invalid names, NUL arguments and oversized encodings fail before dispatch" do
    assert_raise ArgumentError, fn -> Command.new("display-message;kill-server", []) end
    assert_raise ArgumentError, fn -> Command.new("set-option", [<<0>>]) end

    command = Command.new("set-option", [String.duplicate("x", 20)])
    assert_raise ArgumentError, fn -> Command.render(command, max_bytes: 20) end
  end
end
