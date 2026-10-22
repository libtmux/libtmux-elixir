defmodule LibTmux.ControlRequestTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Error, Ref}
  alias LibTmux.Control.Request

  test "resolved empty values and unresolved targets produce distinct outcomes" do
    {:ok, target} = Ref.new(:pane, "%7", "instance")
    request = Request.field("pane_title", target)

    assert {:ok, :ok, ["v1:"]} = Request.normalize_reply(request, :ok, ["t1:%7:v1:"])

    assert {:ok, :ok, ["v1:t1::text"]} =
             Request.normalize_reply(request, :ok, ["t1:%7:v1:t1::text"])

    assert {:ok, :error, [message]} = Request.normalize_reply(request, :ok, ["t1::v1:"])
    assert message =~ "%7"
    assert :ok = Request.verify_reply(request, :ok, ["t1::v1:"])
  end

  test "missing identity, wrong identity and malformed values cannot qualify a target read" do
    {:ok, target} = Ref.new(:pane, "%7", "instance")
    request = Request.field("pane_title", target)

    for reply <- ["v1:value", "t1:%8:v1:value", "t1:%7:raw", "t1::raw", "t1:"] do
      assert {:error, %Error{certainty: :unknown}} =
               Request.normalize_reply(request, :ok, [reply])
    end
  end
end
