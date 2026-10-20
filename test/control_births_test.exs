defmodule LibTmux.ControlBirthsTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Deadline, Error}
  alias LibTmux.Control.{Births, Lifetime}

  test "closing captures every concurrent successful role registration in one frozen map" do
    {births, _lifetime, _generation} = births()
    parent = self()

    actors =
      for role <- [:epoch_supervisor, :router, :guardian] do
        pid =
          start_supervised!(
            Supervisor.child_spec(
              {Task,
               fn ->
                 receive do
                   :start ->
                     send(
                       parent,
                       {:registered, role, self(), Births.register(births, role, now: 1)}
                     )
                 end
               end},
              id: role
            )
          )

        {role, pid}
      end

    for {_role, pid} <- actors, do: send(pid, :start)
    assert {:ok, captured} = Births.close(births)

    for _ <- actors do
      assert_receive {:registered, role, pid, result}

      case result do
        :ok -> assert captured[role] == pid
        {:error, %Error{kind: :startup_closed}} -> assert is_nil(captured[role])
      end
    end

    assert {:ok, ^captured} = Births.close(births)
    assert {:ok, %{gate: :closed, roles: ^captured}} = Births.snapshot(births)
    assert :ets.info(births.table, :size) == 2
  end

  test "one role binds one actor and expired or revoked startup cannot register more" do
    {births, lifetime, generation} = births()
    assert :ok = Births.register(births, :router, now: 1)
    assert :ok = Births.register(births, :router, now: 1)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:duplicate, Births.register(births, :router, now: 1)})
       end}
    )

    assert_receive {:duplicate, {:error, %Error{kind: :role_taken}}}
    assert {:error, %Error{kind: :timeout}} = Births.register(births, :guardian, now: 100)
    assert :ok = Lifetime.revoke(lifetime, generation)
    assert {:error, %Error{kind: :stale_epoch}} = Births.register(births, :guardian, now: 2)
    assert {:ok, %{roles: %{guardian: nil}}} = Births.snapshot(births)
  end

  test "only the real registry owner can close admission and forged context is rejected" do
    {births, _lifetime, _generation} = births()
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:foreign_close, Births.close(births)})
         send(parent, {:forged_close, Births.close(%{births | owner: self()})})
       end}
    )

    assert_receive {:foreign_close, {:error, %Error{kind: :wrong_owner}}}
    assert_receive {:forged_close, {:error, %Error{kind: :wrong_births}}}
    assert :ok = Births.register(births, :guardian, now: 1)
    assert {:ok, %{guardian: pid}} = Births.close(births)
    assert pid == self()
  end

  test "a lost registry cannot authorize late child startup" do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           {births, _life, _gen} = births()
           send(parent, {:births, births})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {:births, births}
    monitor = Process.monitor(owner)
    stop_supervised!(Task)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert {:error, %Error{kind: :connection_lost}} = Births.register(births, :guardian, now: 1)
  end

  defp births do
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)

    {Births.new(lifetime, generation, make_ref(), Deadline.new(100, now: 0)), lifetime,
     generation}
  end
end
