# Run with: elixir scripts/wait_for_hexdocs/tests/wait_for_hexdocs_test.exs
#
# Serves HTTP responses from a local listener, so the real client meets each
# propagation, refusal and stall the release check has to tell apart.

ExUnit.start()

defmodule WaitForHexdocsTest do
  use ExUnit.Case, async: true

  @script Path.expand("../wait_for_hexdocs.exs", __DIR__)

  # Starts a listener that answers by path and counts each GET.
  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    {:ok, counts} = Agent.start_link(fn -> %{} end)
    server = spawn_link(fn -> accept(listener, counts) end)

    on_exit(fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {:ok, port: port, counts: counts}
  end

  defp accept(listener, counts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> respond(socket, counts) end)
        accept(listener, counts)

      {:error, _closed} ->
        :ok
    end
  end

  defp respond(socket, counts) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
    [_, path] = Regex.run(~r/\AGET (\S+) HTTP/, request)

    count =
      Agent.get_and_update(counts, fn all ->
        {Map.get(all, path, 0) + 1, Map.update(all, path, 1, &(&1 + 1))}
      end)

    case {path, count} do
      {"/propagating", 1} -> reply(socket, 404)
      {"/busy", 1} -> reply(socket, 503)
      {"/missing", _} -> reply(socket, 404)
      {"/denied", _} -> reply(socket, 403)
      {"/stalled", _} -> stall(socket)
      _ -> reply(socket, 200)
    end
  end

  defp reply(socket, status) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    :gen_tcp.close(socket)
  end

  # Headers promise a byte that never comes.
  defp stall(socket) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")

    receive do
    after
      5_000 -> :gen_tcp.close(socket)
    end
  end

  defp wait(context, path, budget) do
    started = System.monotonic_time(:millisecond)
    url = "http://127.0.0.1:#{context.port}#{path}"
    {output, status} = System.cmd("elixir", [@script, url, budget], stderr_to_stdout: true)
    elapsed = System.monotonic_time(:millisecond) - started
    {output, status, Agent.get(context.counts, &Map.get(&1, path, 0)), elapsed}
  end

  test "a propagation 404 is retried until the page answers", context do
    assert {output, 0, 2, _} = wait(context, "/propagating", "4")
    assert output =~ "HexDocs ready after 2 attempts"
  end

  test "a 503 is retried", context do
    assert {_output, 0, 2, _} = wait(context, "/busy", "4")
  end

  test "a status that retrying cannot fix fails at once", context do
    assert {output, 1, 1, elapsed} = wait(context, "/denied", "4")
    assert output =~ "HexDocs verification failed: HTTP 403"
    assert elapsed < 3_900
  end

  test "a page that never appears fails at the deadline", context do
    assert {output, 1, 1, _} = wait(context, "/missing", "1")
    assert output =~ "HexDocs readiness deadline after 1s: HTTP 404"
  end

  test "a response that stalls is cut off at the deadline", context do
    assert {output, 1, 1, _} = wait(context, "/stalled", "1")
    assert output =~ "deadline"
  end

  test "a refused connection is retried until the deadline" do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {output, 1} =
             System.cmd("elixir", [@script, "http://127.0.0.1:#{port}/", "2"],
               stderr_to_stdout: true
             )

    assert output =~ "deadline"
    assert output =~ "transport error"
  end

  test "a budget outside 1..120 is refused" do
    for budget <- ["0", "121", "abc", "1.5"] do
      assert {output, 1} =
               System.cmd("elixir", [@script, "http://127.0.0.1:1/", budget],
                 stderr_to_stdout: true
               )

      assert output =~ "budget of 1..120 seconds"
    end
  end
end
