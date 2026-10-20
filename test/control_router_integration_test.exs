defmodule LibTmux.ControlRouterIntegrationTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Codec, Deadline, Server}

  alias LibTmux.Control.{
    Admission,
    Births,
    Bootstrap,
    Guardian,
    Lifetime,
    Records,
    Request,
    Router
  }

  alias LibTmux.Test.OwnedTmux
  alias LibTmux.Transport.Native.Protocol, as: NativeProtocol

  @moduletag :integration
  @moduletag reason:
               "Qualifies FIFO and multiple native fragments over an owned real control connection"

  test "literal mutation and escaped read retain FIFO results across credited fragments" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)
    executable = System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux")
    server = Server.new(executable: executable, socket: socket, cwd: "/", env: %{})
    lifetime = Lifetime.new()
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    pool = Admission.new(2)
    records = Records.new(pool)
    epoch = make_ref()
    bootstrap = make_ref()
    deadline = Deadline.new(800)
    births = Births.new(lifetime, generation, epoch, deadline)

    router =
      start_supervised!(
        {Router,
         manager: self(),
         births: births,
         epoch: epoch,
         lifetime: lifetime,
         generation: generation,
         pool: pool,
         records: records.table,
         bootstrap: bootstrap,
         deadline: deadline}
      )

    payload =
      NativeProtocol.process(executable, Bootstrap.arguments(server, "$0"), cwd: "/", env: %{})

    guardian =
      start_supervised!(
        {Guardian,
         manager: self(),
         births: births,
         router: router,
         epoch: epoch,
         lifetime: lifetime,
         generation: generation,
         pool: pool,
         bootstrap: bootstrap,
         deadline: deadline,
         payload: payload}
      )

    router_monitor = Process.monitor(router)
    guardian_monitor = Process.monitor(guardian)
    send(router, {:bind, self(), epoch, guardian})

    try do
      assert_receive {:router, ^epoch, ^router, {:ready, instance}}, 800
      assert {:ok, %{roles: %{router: ^router, guardian: ^guardian}}} = Births.snapshot(births)
      value = String.duplicate("x", 6000) <> "é\n%end 17 2 1\n#{literal()}"
      write = submit(pool, epoch, router, instance, Request.set_user_option("@router", value))
      read = submit(pool, epoch, router, instance, Request.field("@router"))
      assert_receive {:router, ^epoch, ^router, {:settled, ^write}}, 800
      assert_receive {:router, ^epoch, ^router, {:settled, ^read}}, 800

      assert {:ok,
              %{
                lease: ^write,
                life: %{wire: :retired, result: %{outcome: :completed, lines: []}}
              }} = Records.fetch(records, write)

      assert {:ok,
              %{
                lease: ^read,
                life: %{wire: :retired, result: %{outcome: :completed, lines: [encoded]}}
              }} = Records.fetch(records, read)

      assert {:ok, ^value} = Codec.decode_field(encoded <> "\n", :bytes, encoding: :escaped_v1)
      assert :ok = Records.forget(records, write)
      assert :ok = Records.forget(records, read)
    after
      send(guardian, {:close, self(), epoch, :test_close})
      assert_receive {:guardian, ^epoch, ^guardian, {:closing, _error}}
      assert_receive {:guardian, ^epoch, ^guardian, {:retired, %{cleanup: :retired}}}, 800
      assert_receive {:router, ^epoch, ^router, {:retired, %{cleanup: :retired}}}
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}
      assert_receive {:DOWN, ^router_monitor, :process, ^router, :normal}
      assert :ok = Lifetime.retired(lifetime, generation)
    end

    assert {"0\n", 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", ~S"#{session_attached}"])
  end

  defp literal, do: ~S"#{pid}; run-shell false"

  defp submit(pool, epoch, router, instance, request) do
    {:ok, line} = Request.encode(request, instance)
    {:ok, lease} = Admission.claim(pool, epoch, router, Deadline.new(800), byte_size(line))
    send(router, {:submit, epoch, lease, request})
    lease
  end
end
