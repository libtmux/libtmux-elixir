defmodule LibTmux.ControlPublicStartTest do
  use ExUnit.Case, async: true
  alias LibTmux.{Control, Error, Server}
  alias LibTmux.Control.Lifetime

  test "startup requires explicit bounded server, existing session and qualified lane" do
    options = options()
    {:links, links} = Process.info(self(), :links)

    invalid = [
      Keyword.delete(options, :server),
      Keyword.delete(options, :session),
      Keyword.delete(options, :lane),
      Keyword.put(options, :session, {:ensure, "dev"}),
      Keyword.put(options, :session, {:existing, "dev"}),
      Keyword.put(options, :lane, :raw),
      Keyword.put(options, :driver, {__MODULE__, []}),
      Keyword.put(options, :timeout, 0),
      Keyword.put(options, :timeout, 18_446_744_073_709_551_615),
      Keyword.put(options, :capacity, 257),
      Keyword.put(options, :server, %{options[:server] | socket: "relative"}),
      Keyword.put(options, :server, %{options[:server] | socket: "/bad\0socket"}),
      Keyword.put(options, :server, %{options[:server] | socket_name: "work"}),
      Keyword.put(options, :server, %{options[:server] | socket: nil, socket_name: "a/b"}),
      Keyword.put(options, :server, %{options[:server] | socket: nil, socket_name: ""})
    ]

    for input <- invalid do
      assert_raise ArgumentError, fn -> Control.child_spec(input) end
    end

    assert {:links, ^links} = Process.info(self(), :links)
  end

  test "startup accepts a socket name or no socket at all" do
    for server <- [
          Server.new(executable: "/unused/tmux", socket_name: "work", cwd: "/", env: %{}),
          Server.new(executable: "/unused/tmux", cwd: "/", env: %{})
        ] do
      assert %{start: {_module, :start_link, [_prepared]}} =
               Control.child_spec(Keyword.put(options(), :server, server))
    end
  end

  test "a prepared factory retains a detached payload rather than the original environment" do
    parent = :binary.copy("v", 1_000_000)
    value = binary_part(parent, 0, 4096)
    server = %{options()[:server] | env: %{"KEEP" => value, "TMUX" => "ambient"}}
    spec = Control.child_spec(Keyword.put(options(), :server, server))
    %{start: {_module, _function, [prepared]}} = spec
    payload = prepared.options[:payload]

    assert byte_size(payload) < 32_768
    assert :binary.referenced_byte_size(payload) == byte_size(payload)
    assert :binary.match(payload, "KEEP=") != :nomatch
    assert :binary.match(payload, "ambient") == :nomatch
    refute Map.has_key?(prepared, :server)
  end

  test "a prepared factory keeps TMUX only for a server that chose no socket" do
    env = %{"TMUX" => "ambient-tmux", "TMUX_PANE" => "ambient-pane"}

    for {server, kept?} <- [
          {Server.new(executable: "/unused/tmux", cwd: "/", env: env), true},
          {Server.new(executable: "/unused/tmux", socket: "/unused/socket", cwd: "/", env: env),
           false},
          {Server.new(executable: "/unused/tmux", socket_name: "work", cwd: "/", env: env), false}
        ] do
      %{start: {_module, _function, [prepared]}} =
        Control.child_spec(Keyword.put(options(), :server, server))

      payload = prepared.options[:payload]

      assert :binary.match(payload, "TMUX=ambient-tmux") != :nomatch == kept?
      assert :binary.match(payload, "TMUX_PANE=ambient-pane") != :nomatch == kept?
    end
  end

  test "a retired factory restart returns inert fresh info without following the old handle" do
    spec = Control.child_spec(options())
    %{start: {_module, _function, [prepared]}} = spec
    lifetime = prepared.options[:lifetime]
    {:ok, generation} = Lifetime.begin_epoch(lifetime)
    :ok = Lifetime.revoke(lifetime, generation)
    :ok = Lifetime.retired(lifetime, generation)
    parent = parent()

    assert {:ok, root, control} = Supervisor.start_child(parent, spec)
    assert {:ok, %{phase: :retired, generation: ^generation}} = Control.status(control)
    assert :ets.info(control.view, :owner) == root
    [{:host, host}] = :ets.lookup(control.view, :host)
    assert [] = Supervisor.which_children(host)
    assert :ok = Control.close(control, timeout: 100)
    monitor = Process.monitor(root)
    assert :ok = Supervisor.terminate_child(parent, Control)
    assert_receive {:DOWN, ^monitor, :process, ^root, _reason}, 100
    assert {:ok, replacement, fresh} = Supervisor.restart_child(parent, Control)
    assert replacement != root
    assert fresh.lifetime === control.lifetime
    assert {:ok, %{phase: :retired}} = Control.status(fresh)
    assert {:error, %Error{kind: :connection_lost}} = Control.status(control)
  end

  test "a fenced generation zero remains inert and returns structured lifecycle failures" do
    spec = Control.child_spec(options())
    %{start: {_module, _function, [prepared]}} = spec
    :ok = Lifetime.abandon_initial(prepared.options[:lifetime])

    assert {:ok, _root, control} = Supervisor.start_child(parent(), spec)
    assert {:ok, %{phase: :unknown, generation: 0}} = Control.status(control)

    assert {:error, %Error{kind: :cleanup_unknown, phase: :close, certainty: :unknown}} =
             Control.close(control, timeout: 100)

    assert {:error, %Error{kind: :cleanup_unknown, phase: :connect, certainty: :unknown}} =
             Control.reconnect(control, timeout: 100)

    assert %{generation: 0, phase: :unknown} = Lifetime.status(control.lifetime)
  end

  defp options do
    server = Server.new(executable: "/unused/tmux", socket: "/unused/socket", cwd: "/", env: %{})
    [server: server, session: {:existing, "$0"}, lane: :host_qualified, timeout: 500]
  end

  defp parent do
    start_supervised!(%{
      id: :parent,
      start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
      type: :supervisor
    })
  end
end
