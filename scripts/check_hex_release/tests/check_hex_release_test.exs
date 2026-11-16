# Run with: elixir scripts/check_hex_release/tests/check_hex_release_test.exs
#
# Serves release documents from a local listener, so the real client meets a
# matching release, a release of another version, one with a requirement, a
# missing release and a document that is not JSON.

Code.require_file("../check_hex_release.exs", __DIR__)
ExUnit.start()

defmodule CheckHexReleaseTest do
  use ExUnit.Case, async: true

  @script Path.expand("../check_hex_release.exs", __DIR__)

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> accept(listener) end)

    on_exit(fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {:ok, port: port}
  end

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> respond(socket) end)
        accept(listener)

      {:error, _closed} ->
        :ok
    end
  end

  defp respond(socket) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
    [_, path] = Regex.run(~r/\AGET (\S+) HTTP/, request)

    case path do
      "/match" -> reply(socket, 200, ~s({"version": "0.1.1", "requirements": {}}))
      "/other" -> reply(socket, 200, ~s({"version": "0.1.0", "requirements": {}}))
      "/required" -> reply(socket, 200, ~s({"version": "0.1.1", "requirements": {"jason": {}}}))
      "/text" -> reply(socket, 200, "not json")
      _missing -> reply(socket, 404, "{}")
    end
  end

  defp reply(socket, status, body) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
      )

    :gen_tcp.close(socket)
  end

  defp check(context, path, version \\ "0.1.1") do
    url = "http://127.0.0.1:#{context.port}#{path}"
    System.cmd("elixir", [@script, url, version], stderr_to_stdout: true)
  end

  test "a release that names the version and declares no requirement passes", context do
    assert {output, 0} = check(context, "/match")
    assert output =~ "Hex release 0.1.1 declares no requirement"
  end

  test "a release of another version fails", context do
    assert {output, 1} = check(context, "/other")
    assert output =~ "is not version 0.1.1"
  end

  test "a release with a requirement fails", context do
    assert {output, 1} = check(context, "/required")
    assert output =~ "with no requirements"
  end

  test "a document that is not JSON fails", context do
    assert {_output, 1} = check(context, "/text")
  end

  test "a status other than 200 fails", context do
    assert {output, 1} = check(context, "/missing")
    assert output =~ "HTTP 404"
  end

  test "a refused connection fails" do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {output, 1} =
             System.cmd("elixir", [@script, "http://127.0.0.1:#{port}/", "0.1.1"],
               stderr_to_stdout: true
             )

    assert output =~ "Hex release request failed"
  end

  test "the arguments are checked" do
    assert {output, 1} = System.cmd("elixir", [@script], stderr_to_stdout: true)
    assert output =~ "usage:"
  end
end
