defmodule LibTmux.ControlAdmissionTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.Admission

  test "publication count and encoded bytes are bounded before a lease can be consumed" do
    pool = Admission.new(1, max_bytes: 64)
    epoch = make_ref()
    deadline = Deadline.new(100, now: 0)

    assert_raise ArgumentError, fn ->
      Admission.claim(pool, epoch, self(), Deadline.new(Integer.pow(2, 128), now: 0), 1, now: 0)
    end

    assert {:error, %Error{kind: :timeout}} =
             Admission.claim(pool, epoch, self(), deadline, 1, now: 100)

    assert {:error, %Error{kind: :resource_limit}} =
             Admission.claim(pool, epoch, self(), deadline, 65, now: 0)

    assert {:ok, lease} = Admission.claim(pool, epoch, self(), deadline, 64, now: 0)

    assert {:error, %Error{kind: :resource_limit}} =
             Admission.claim(pool, epoch, self(), deadline, 1, now: 0)

    assert {:error, %Error{kind: :unconsumed_lease}} = Admission.release(pool, lease)
    assert {:error, %Error{kind: :resource_limit}} = Admission.consume(pool, lease, 65)
    assert :ok = Admission.consume(pool, lease, 64)
    assert :ok = Admission.release(pool, lease)
    assert {:ok, next} = Admission.claim(pool, epoch, self(), deadline, 1, now: 0)
    assert next != lease
    assert {:error, %Error{kind: :stale_lease}} = Admission.consume(pool, lease, 64)
    assert {:error, %Error{kind: :stale_lease}} = Admission.release(pool, lease)

    forged = %{next | generation: :"$1", epoch: :"$2", publisher: :"$3", expires_at: :"$4"}

    for invalid <- [forged, %{next | generation: next.generation * 1.0}] do
      assert {:error, %Error{kind: :stale_lease}} = Admission.consume(pool, invalid, 1)
    end

    assert :ok = Admission.consume(pool, next, 1)
  end

  test "expired suspended publication retains capacity until the destination consumes it" do
    pool = Admission.new(1)
    epoch = make_ref()
    parent = self()
    deadline = Deadline.new(100, now: 0)

    publisher =
      start_supervised!(
        {Task,
         fn ->
           {:ok, lease} = Admission.claim(pool, epoch, parent, deadline, 8, now: 0)
           send(parent, {:reserved, lease})

           receive do
             :publish -> send(parent, {:publication, lease})
           end
         end}
      )

    assert_receive {:reserved, lease}
    assert {:ok, [^lease]} = Admission.unpublished_expired(pool, now: 100)
    assert {:error, %Error{kind: :unconsumed_lease}} = Admission.release(pool, lease)

    assert {:error, %Error{kind: :live_destination}} =
             Admission.retire_destination(pool, epoch, self())

    assert {:error, %Error{kind: :resource_limit}} =
             Admission.claim(pool, epoch, self(), Deadline.new(100, now: 100), 1, now: 100)

    send(publisher, :publish)
    assert_receive {:publication, ^lease}
    assert :ok = Admission.consume(pool, lease, 8)
    assert {:ok, []} = Admission.unpublished_expired(pool, now: 100)
    assert :ok = Admission.release(pool, lease)
  end

  test "only the pool owner reclaims a dead destination and old publications stay stale" do
    pool = Admission.new(1)
    parent = self()

    destination =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:release, lease} -> send(parent, {:outsider, Admission.release(pool, lease)})
           end

           receive do
             :finish -> :ok
           end
         end}
      )

    epoch = make_ref()
    deadline = Deadline.new(100, now: 0)
    assert {:ok, lease} = Admission.claim(pool, epoch, destination, deadline, 8, now: 0)
    assert {:error, %Error{kind: :wrong_destination}} = Admission.consume(pool, lease, 8)
    send(destination, {:release, lease})
    assert_receive {:outsider, {:error, %Error{kind: :wrong_owner}}}
    monitor = Process.monitor(destination)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^destination, :shutdown}
    assert {:ok, 1} = Admission.retire_destination(pool, epoch, destination)
    assert {:ok, replacement} = Admission.claim(pool, make_ref(), self(), deadline, 8, now: 0)
    assert replacement != lease
    assert {:error, %Error{kind: :stale_lease}} = Admission.release(pool, lease)
    assert :ok = Admission.consume(pool, replacement, 8)
  end

  test "concurrent publishers cannot exceed the fixed slot count" do
    pool = Admission.new(1)
    epoch = make_ref()
    parent = self()
    deadline = Deadline.new(100, now: 0)

    for index <- 1..32 do
      child =
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:claim, Admission.claim(pool, epoch, parent, deadline, 8, now: 0)})
           end},
          id: {:publisher, index}
        )

      start_supervised!(child)
    end

    results =
      for _ <- 1..32 do
        assert_receive {:claim, result}
        result
      end

    assert [{:ok, lease}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, %Error{kind: :resource_limit}}, &1)) == 31
    assert :ok = Admission.consume(pool, lease, 8)
    assert :ok = Admission.release(pool, lease)
  end

  test "loss of the owning table cannot become free capacity" do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           send(parent, {:pool, Admission.new(1)})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {:pool, pool}
    monitor = Process.monitor(owner)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}

    assert {:error, %Error{kind: :connection_lost}} =
             Admission.claim(pool, make_ref(), self(), Deadline.new(100), 8)
  end
end
