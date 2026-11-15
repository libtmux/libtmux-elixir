defmodule LibTmux.ServerLifecycleTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Error, Server}

  defp refused(options) do
    assert {:error, %Error{kind: :invalid_command, phase: :validation, certainty: :no_write} = e} =
             Server.start(options)

    e
  end

  test "start needs an absolute executable" do
    assert %Error{path: [:options, :executable]} = refused([])
    assert %Error{path: [:options, :executable]} = refused(executable: "tmux")
    assert %Error{path: [:options, :executable]} = refused(executable: 7)
  end

  test "start refuses a root that is not an existing absolute directory" do
    assert %Error{path: [:options, :root]} = refused(executable: "/bin/true", root: "relative")

    assert %Error{path: [:options, :root]} =
             refused(executable: "/bin/true", root: "/does/not/exist")
  end

  test "start refuses a root whose socket path would not fit sun_path" do
    root = Path.join(System.tmp_dir!(), String.duplicate("d", 100))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert %Error{path: [:options, :root], details: %{reason: reason}} =
             refused(executable: "/bin/true", root: root)

    assert reason =~ "sun_path"
  end

  test "start refuses unknown and malformed options" do
    assert %Error{path: [:options, :shell]} = refused(executable: "/bin/true", shell: "sh")

    assert %Error{path: [:options, :config_file]} =
             refused(executable: "/bin/true", config_file: "tmux.conf")

    assert %Error{path: [:options, :env]} = refused(executable: "/bin/true", env: [{"A", "b"}])
    assert %Error{path: [:options, :timeout]} = refused(executable: "/bin/true", timeout: 0)
    assert %Error{path: [:options, :timeout]} = refused(executable: "/bin/true", timeout: 600_001)
  end

  test "stop refuses a server that start did not create" do
    server = Server.new(executable: "/bin/true", socket: "/tmp/not-owned.sock")

    assert {:error, %Error{kind: :not_owned, phase: :validation, certainty: :no_write}} =
             Server.stop(server)
  end

  test "with_owned raises the start error and never calls the function" do
    parent = self()

    assert_raise Error, ~r/invalid_command/, fn ->
      Server.with_owned([], fn _server -> send(parent, :called) end)
    end

    refute_received :called
  end
end
