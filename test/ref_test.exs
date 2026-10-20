defmodule LibTmux.RefTest do
  use ExUnit.Case, async: true

  alias LibTmux.Ref

  test "exact pane IDs reject positional and malformed targets" do
    assert {:ok, ref} = Ref.new(:pane, "%7", "instance-a")
    assert ref.id == "%7"
    assert ref.entity == :pane

    for id <- ["7", "main:0.1", "%7\n", "%+7", "%07", "%-1", "@7", ""] do
      assert {:error, %{kind: :invalid_target, certainty: :no_write}} =
               Ref.new(:pane, id, "instance-a")
    end
  end

  test "references cannot be rebound across server instances" do
    assert {:ok, ref} = Ref.new(:pane, "%7", "instance-a")
    assert :ok = Ref.validate(ref, "instance-a")

    assert {:error, %{kind: :stale_target, certainty: :no_write}} =
             Ref.validate(ref, "instance-b")
  end

  test "window-link references retain the complete observed binding" do
    assert {:ok, link} = Ref.new(:window_link, {"$1", 5, "@4"}, "instance-a")
    assert link.id == {"$1", 5, "@4"}

    assert {:error, %{kind: :invalid_target}} =
             Ref.new(:window_link, {"$1", -1, "@4"}, "instance-a")
  end
end
