defmodule LibTmux.DeadlineTest do
  use ExUnit.Case, async: true

  alias LibTmux.Deadline

  test "one budget expires without restarting between stages" do
    deadline = Deadline.new(50, now: 100)
    assert Deadline.remaining(deadline, now: 110) == 40
    assert Deadline.remaining(deadline, now: 149) == 1
    assert Deadline.remaining(deadline, now: 150) == 0
    assert Deadline.remaining(deadline, now: 200) == 0
  end

  test "invalid timeout values fail before admission" do
    for value <- [0, -1, 1.5, :infinity, nil] do
      assert_raise ArgumentError, fn -> Deadline.new(value) end
    end
  end
end
