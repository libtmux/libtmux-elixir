defmodule LibTmux.ControlRecordsTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Admission, Records}
  alias LibTmux.Operation.Lifecycle

  test "dead destinations retain reserved and consumed-without-record outcomes until explicit release" do
    pool = Admission.new(2)
    records = Records.new(pool)
    parent = self()
    epoch = make_ref()

    destination =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:consume, lease} ->
               :ok = Admission.consume(pool, lease, 5)
               send(parent, :consumed)
           end

           receive do
             :finish -> :ok
           end
         end}
      )

    {:ok, reserved} = Admission.claim(pool, epoch, destination, Deadline.new(500), 5)
    {:ok, consumed} = Admission.claim(pool, epoch, destination, Deadline.new(500), 5)
    send(destination, {:consume, consumed})
    assert_receive :consumed
    assert :pending = Records.fetch(records, consumed)

    assert {:error, %Error{kind: :live_destination}} =
             Records.finalize(records, epoch, destination)

    monitor = Process.monitor(destination)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^destination, :shutdown}
    assert {:ok, 2} = Records.finalize(records, epoch, destination)

    for lease <- [reserved, consumed] do
      assert {:ok, %{life: %{wire: :retired, result: %{outcome: :skipped, certainty: :no_write}}}} =
               Records.fetch(records, lease)
    end

    assert {:error, %Error{kind: :resource_limit}} =
             Admission.claim(pool, make_ref(), self(), Deadline.new(500), 5)

    assert :ok = Records.forget(records, reserved)
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(records, reserved)
    assert :ok = Records.forget(records, consumed)
    assert {:ok, []} = Admission.entries(pool)
  end

  test "router-death fallback preserves acknowledged results and classifies dispatched uncertainty" do
    pool = Admission.new(3)
    records = Records.new(pool)
    parent = self()
    epoch = make_ref()

    destination =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:consume, leases} ->
               for lease <- leases, do: :ok = Admission.consume(pool, lease, 5)
               send(parent, :consumed)
           end

           receive do
             :finish -> :ok
           end
         end}
      )

    leases =
      for _ <- 1..3 do
        {:ok, lease} = Admission.claim(pool, epoch, destination, Deadline.new(500), 5)
        lease
      end

    send(destination, {:consume, leases})
    assert_receive :consumed
    [acknowledged, writing, unsent] = leases

    for lease <- leases do
      token = make_ref()
      life = Lifecycle.new(epoch, token, %Deadline{expires_at: lease.expires_at}, 5)

      life =
        if lease == unsent do
          life
        else
          {:ok, life, _} = Lifecycle.step(life, {:owner, epoch, token, :dispatch})
          life
        end

      life =
        if lease == acknowledged do
          {:ok, life, _} =
            Lifecycle.step(life, {:owner, epoch, token, {:reply, :ok, {1, 1, 1}, ["value"]}})

          life
        else
          life
        end

      :ets.insert(
        records.table,
        {lease.slot, %{lease: lease, token: token, life: life, reply: nil}}
      )
    end

    assert {:error, %Error{kind: :wire_active}} = Records.forget(records, writing)
    monitor = Process.monitor(destination)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^destination, :shutdown}
    assert {:ok, 3} = Records.finalize(records, epoch, destination)

    assert {:ok, %{life: %{result: %{outcome: :completed, lines: ["value"]}}}} =
             Records.fetch(records, acknowledged)

    assert {:ok, %{life: %{result: %{outcome: :unknown, certainty: :unknown}}}} =
             Records.fetch(records, writing)

    assert {:ok, %{life: %{result: %{outcome: :skipped, certainty: :no_write}}}} =
             Records.fetch(records, unsent)

    for lease <- leases, do: :ok = Records.forget(records, lease)
    {:ok, replacement} = Admission.claim(pool, make_ref(), self(), Deadline.new(500), 5)
    assert :pending = Records.fetch(records, replacement)
    assert {:error, %Error{kind: :stale_operation}} = Records.fetch(records, acknowledged)
  end

  test "registry handles cannot substitute pool authority or forget another generation" do
    pool = Admission.new(1)
    records = Records.new(pool)
    {:ok, lease} = Admission.claim(pool, make_ref(), self(), Deadline.new(500), 5)
    assert :ok = Admission.consume(pool, lease, 5)

    assert {:error, %Error{kind: :stale_operation}} =
             Records.fetch(records, %{lease | generation: 1.0})

    assert {:error, %Error{kind: :wrong_records}} =
             Records.fetch(%{records | pool: %{pool | max_bytes: 5}}, lease)

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:foreign_forget, Records.forget(records, lease)})

         result =
           try do
             Records.new(%{pool | owner: self()})
             :accepted
           rescue
             ArgumentError -> :rejected
           end

         send(parent, {:foreign_constructor, result})
       end}
    )

    assert_receive {:foreign_forget, {:error, %Error{kind: :wrong_owner}}}
    assert_receive {:foreign_constructor, :rejected}
    assert :ok = Admission.verify_consumed(pool, lease)
  end
end
