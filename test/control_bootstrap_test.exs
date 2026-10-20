defmodule LibTmux.ControlBootstrapTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Bootstrap

  test "a fresh post-identity challenge requires both its reply and its complete write" do
    for order <- [[:reply, :written], [:written, :reply]] do
      initial = Bootstrap.new(Deadline.new(500))
      assert {:ok, state, []} = Bootstrap.event(initial, {:reply, :ok, {1, 17, 0}, []})

      assert {:ok, state, [{:identity, 123}]} =
               Bootstrap.event(state, {:reply, :ok, {1, 22, 0}, ["123"]})

      assert {:ok, state, nonce} = Bootstrap.bind_identity(state, "linux:boot:123:456")

      [first, second] =
        Enum.map(order, fn
          :reply -> {:reply, :ok, {1, 38, 1}, [nonce <> ":123"]}
          :written -> :written
        end)

      assert {:ok, state, []} = Bootstrap.event(state, first)
      assert {:ok, state, [:activate]} = Bootstrap.event(state, second)
      assert {:ok, "linux:boot:123:456"} = Bootstrap.identity(state)
      assert {:error, %Error{kind: :invalid_bootstrap}} = Bootstrap.event(state, second)
    end
  end

  test "unexpected startup blocks and expired or mismatched challenges cannot identify a server" do
    initial = Bootstrap.new(Deadline.new(100, now: 0))

    assert {:error, %Error{kind: :invalid_bootstrap}} =
             Bootstrap.event(initial, {:reply, :ok, {1, 1, 0}, ["%config-error bad"]}, now: 0)

    assert {:error, %Error{kind: :command_error}} =
             Bootstrap.event(initial, {:reply, :error, {1, 1, 0}, ["no sessions"]}, now: 0)

    assert {:ok, state, []} = Bootstrap.event(initial, {:reply, :ok, {1, 1, 0}, []}, now: 0)

    assert {:error, %Error{kind: :invalid_bootstrap}} =
             Bootstrap.event(state, {:reply, :ok, {1, 2, 0}, []}, now: 0)

    assert {:ok, state, [{:identity, 123}]} =
             Bootstrap.event(state, {:reply, :ok, {1, 2, 0}, ["123"]}, now: 0)

    assert {:ok, state, nonce} = Bootstrap.bind_identity(state, "linux:boot:123:456", now: 0)

    assert {:error, %Error{kind: :invalid_bootstrap}} =
             Bootstrap.event(state, {:reply, :ok, {1, 3, 1}, [nonce <> ":124"]}, now: 0)

    assert {:error, %Error{kind: :timeout}} =
             Bootstrap.event(state, {:reply, :ok, {1, 3, 1}, [nonce <> ":123"]}, now: 100)

    assert {:error, %Error{kind: :identity_unavailable}} = Bootstrap.identity(state)
  end
end
