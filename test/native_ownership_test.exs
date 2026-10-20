defmodule LibTmux.NativeOwnershipTest do
  use ExUnit.Case, async: false

  alias LibTmux.Transport.Native

  @moduletag :integration
  @moduletag reason:
               "Qualifies native protocol faults, blocked I/O and Linux process-tree retirement"

  test "the private helper preserves bounded credits, partial writes and retirement under faults" do
    for script <- ["io_contract.py", "io_faults.py"] do
      {output, status} =
        System.cmd(System.find_executable("python3"), [Path.join(__DIR__, "support/#{script}")],
          env: [{"LIBTMUX_IO_HELPER", Native.executable()}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      refute String.contains?(output, ~s("status": "FAIL")), output
    end
  end

  test "owner and VM death retire helper descendants while an unrelated process survives" do
    root =
      Path.join(System.tmp_dir!(), "ltx-vm-#{System.pid()}-#{System.unique_integer([:positive])}")

    File.mkdir!(root)

    try do
      {output, status} =
        System.cmd(
          System.find_executable("erlc"),
          ["-Werror", "-o", root, Path.join(__DIR__, "support/libtmux_io_vm.erl")],
          stderr_to_stdout: true
        )

      assert status == 0, output

      for mode <- ["owner", "vm"] do
        {output, status} =
          System.cmd(
            System.find_executable("python3"),
            [
              Path.join(__DIR__, "support/io_vm_death.py"),
              mode,
              System.find_executable("erl"),
              root
            ],
            env: [{"LIBTMUX_IO_SPIKE", Native.executable()}],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert JSON.decode!(output)["unrelated_survived"]
      end
    after
      File.rm_rf!(root)
    end
  end

  test "a suspended BEAM owner receives only its credited flood bytes" do
    {output, status} =
      System.cmd(System.find_executable("elixir"), [Path.join(__DIR__, "support/io_bound.exs")],
        env: [{"LIBTMUX_IO_HELPER", Native.executable()}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    result = JSON.decode!(output)
    assert result["streams"] == 2
    assert result["messages"] <= 4
    assert result["binary_bytes"] <= 65_536
  end
end
