defmodule LibTmux.ControlLifetimeTest do
  use ExUnit.Case, async: true
  alias LibTmux.Control.Lifetime
  alias LibTmux.Error

  test "write authority closes before retirement and old tokens cannot affect a replacement" do
    lifetime = Lifetime.new()
    assert {:ok, first} = Lifetime.begin_epoch(lifetime)
    refute Lifetime.allows_write?(lifetime, first)
    assert :ok = Lifetime.ready(lifetime, first)
    assert Lifetime.allows_write?(lifetime, first)
    assert {:error, %Error{kind: :unretired_epoch}} = Lifetime.begin_epoch(lifetime)
    assert :ok = Lifetime.revoke(lifetime, first)
    refute Lifetime.allows_write?(lifetime, first)
    assert {:error, %Error{kind: :unretired_epoch}} = Lifetime.begin_epoch(lifetime)
    assert :ok = Lifetime.retired(lifetime, first)
    assert {:ok, second} = Lifetime.begin_epoch(lifetime)
    assert second != first
    assert :ok = Lifetime.ready(lifetime, second)

    for transition <- [
          &Lifetime.ready/2,
          &Lifetime.revoke/2,
          &Lifetime.retired/2,
          &Lifetime.abandon/2
        ] do
      assert {:error, %Error{kind: :stale_epoch}} = transition.(lifetime, first)
    end

    assert Lifetime.allows_write?(lifetime, second)
    assert {:error, %Error{kind: :invalid_transition}} = Lifetime.retired(lifetime, second)

    starting = Lifetime.new()
    assert {:ok, token} = Lifetime.begin_epoch(starting)
    assert :ok = Lifetime.revoke(starting, token)
    assert :ok = Lifetime.revoke(starting, token)
    assert {:error, %Error{kind: :invalid_transition}} = Lifetime.ready(starting, token)
    assert %{phase: :closing} = Lifetime.status(starting)

    assert {:error, %Error{kind: :stale_epoch}} =
             Lifetime.revoke(starting, Integer.pow(2, 64))
  end

  test "an unretired reference survives creator death and uncertainty cannot reopen it" do
    parent = self()

    {creator, monitor} =
      spawn_monitor(fn ->
        lifetime = Lifetime.new()
        {:ok, token} = Lifetime.begin_epoch(lifetime)
        send(parent, {:lifetime, lifetime, token})
      end)

    assert_receive {:lifetime, lifetime, token}
    assert_receive {:DOWN, ^monitor, :process, ^creator, :normal}
    assert {:error, %Error{kind: :unretired_epoch}} = Lifetime.begin_epoch(lifetime)
    assert :ok = Lifetime.abandon(lifetime, token)
    assert :ok = Lifetime.abandon(lifetime, token)
    refute Lifetime.allows_write?(lifetime, token)
    assert %{phase: :unknown, generation: ^token} = Lifetime.status(lifetime)

    for transition <- [&Lifetime.ready/2, &Lifetime.revoke/2, &Lifetime.retired/2] do
      assert {:error, %Error{kind: :cleanup_unknown}} = transition.(lifetime, token)
    end

    assert {:error, %Error{kind: :cleanup_unknown}} = Lifetime.begin_epoch(lifetime)
  end

  test "competing epoch reservations grant one writer generation" do
    lifetime = Lifetime.new()
    parent = self()

    readers =
      for _ <- 1..32,
          do: spawn(fn -> send(parent, {:reservation, Lifetime.begin_epoch(lifetime)}) end)

    results =
      for _ <- readers do
        assert_receive {:reservation, result}
        result
      end

    assert [{:ok, token}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, %Error{kind: :unretired_epoch}}, &1)) == 31
    assert %{phase: :starting, generation: ^token} = Lifetime.status(lifetime)
    refute Lifetime.allows_write?(lifetime, token)

    assert :ok = Lifetime.ready(lifetime, token)

    closers =
      for _ <- 1..32,
          do: spawn(fn -> send(parent, {:revoked, Lifetime.revoke(lifetime, token)}) end)

    for _ <- closers, do: assert_receive({:revoked, :ok})
    refute Lifetime.allows_write?(lifetime, token)
    assert :ok = Lifetime.retired(lifetime, token)
  end
end
