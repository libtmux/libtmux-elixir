defmodule LibTmux.ControlStartupTest do
  use ExUnit.Case, async: true
  alias LibTmux.Deadline
  alias LibTmux.Control.{Admission, Births, Guardian, Lifetime, Records, Router}
  alias LibTmux.Test.NativeDriver
  @moduletag :capture_log

  test "a closed startup rejects Guardian before opening a native driver" do
    {births, options} = startup()
    assert {:ok, _roles} = Births.close(births)

    assert {:error, _reason} =
             start_supervised(
               {Guardian,
                options ++
                  [router: self(), payload: <<0>>, driver: {NativeDriver, observer: self()}]}
             )

    refute_receive {:driver_open, _, _}, 0
  end

  test "a closed startup rejects Router before publishing readiness" do
    {births, options} = startup()
    assert {:ok, _roles} = Births.close(births)
    assert {:error, _reason} = start_supervised({Router, options})
    refute_receive {:router, _, _, _}, 0
  end

  test "an expired original startup deadline prevents opening a native driver" do
    {_births, options} = startup()

    options =
      options
      |> Keyword.delete(:births)
      |> Keyword.put(:deadline, Deadline.new(1, now: System.monotonic_time(:millisecond) - 10))

    assert {:error, _reason} =
             start_supervised(
               {Guardian,
                options ++
                  [router: self(), payload: <<0>>, driver: {NativeDriver, observer: self()}]}
             )

    refute_receive {:driver_open, _, _}, 0
  end

  defp startup do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    deadline = Deadline.new(500)
    epoch = make_ref()
    births = Births.new(lifetime, generation, epoch, deadline)
    pool = Admission.new(1)
    records = Records.new(pool)

    {births,
     [
       births: births,
       manager: self(),
       lifetime: lifetime,
       generation: generation,
       deadline: deadline,
       epoch: epoch,
       pool: pool,
       records: records.table,
       bootstrap: make_ref()
     ]}
  end
end
