defmodule LibTmux.ReplyTest do
  use ExUnit.Case, async: true

  test "closing a reply alias releases an already-delivered result and rejects later delivery" do
    reply = :erlang.alias()
    token = make_ref()
    payload = :binary.copy("bounded result", 4096)
    send(reply, {token, payload})
    send(self(), {:unrelated, token})

    LibTmux.Transport.Reply.close(reply, token)

    refute_received {^token, _}
    send(reply, {token, payload})
    refute_received {^token, _}
    assert_received {:unrelated, ^token}
  end
end
