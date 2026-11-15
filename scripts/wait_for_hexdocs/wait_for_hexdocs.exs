# Waits for a published HexDocs page to answer 200.
#
# Usage: elixir scripts/wait_for_hexdocs/wait_for_hexdocs.exs URL [BUDGET]
#
# URL is the versioned HexDocs page. BUDGET is the whole wait in seconds, 1..120,
# 60 by default. Each request is limited to five seconds or what is left of the
# budget. A propagation 404, a timeout, 408, 429, a 5xx and a refused or dropped
# connection are retried a second later; any other status fails at once.
# Exits 0 when the page answers 200 and 1 otherwise.

defmodule WaitForHexdocs do
  @moduledoc false

  @request_ms 5_000
  @retry_ms 1_000

  def main(arguments) do
    case parse(arguments) do
      {:ok, url, budget} -> wait(url, budget)
      :error -> fail("HexDocs wait requires a budget of 1..120 seconds")
    end
  end

  defp parse([url]), do: parse([url, "60"])

  defp parse([url, budget]) do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,2}\z/, budget),
         seconds when seconds <= 120 <- String.to_integer(budget) do
      {:ok, url, seconds}
    else
      _ -> :error
    end
  end

  defp parse(_arguments), do: fail("usage: elixir wait_for_hexdocs.exs URL [BUDGET]")

  defp wait(url, budget) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    started = System.monotonic_time(:millisecond)
    attempt(url, started, started + budget * 1000, 0, nil)
  end

  defp attempt(url, started, deadline, attempts, last) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      seconds = div(System.monotonic_time(:millisecond) - started, 1000)

      fail(
        "HexDocs readiness deadline after #{seconds}s: #{describe(last)}, #{attempts} attempts"
      )
    else
      attempts = attempts + 1

      case request(url, min(remaining, @request_ms)) do
        {:status, 200} ->
          seconds = div(System.monotonic_time(:millisecond) - started, 1000)
          IO.puts("HexDocs ready after #{attempts} attempts (#{seconds}s)")

        result ->
          if retry?(result) do
            if System.monotonic_time(:millisecond) < deadline, do: Process.sleep(@retry_ms)
            attempt(url, started, deadline, attempts, result)
          else
            fail("HexDocs verification failed: #{describe(result)}, attempt #{attempts}")
          end
      end
    end
  end

  defp request(url, milliseconds) do
    options =
      [timeout: milliseconds, connect_timeout: milliseconds, autoredirect: true] ++ tls(url)

    case :httpc.request(:get, {String.to_charlist(url), []}, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:status, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tls("https://" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp tls(_url), do: []

  defp retry?({:status, status}), do: status in [404, 408, 429] or status in 500..599

  defp retry?({:error, reason}),
    do: reason == :timeout or reason == :socket_closed_remotely or connection_failure?(reason)

  # A refused or unreachable endpoint may start answering; a failed TLS check will not.
  defp connection_failure?({:failed_connect, details}),
    do: not Enum.any?(details, &match?({:tls_alert, _}, &1))

  defp connection_failure?(_reason), do: false

  defp describe({:status, status}), do: "HTTP #{status}"
  defp describe({:error, reason}), do: "transport error #{inspect(reason, limit: 4)}"
  defp describe(nil), do: "no response"

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: WaitForHexdocs.main(System.argv())
