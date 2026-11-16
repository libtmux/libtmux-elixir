# Checks a published Hex release.
#
# Usage: elixir scripts/check_hex_release/check_hex_release.exs URL VERSION
#
# URL is the Hex API page of the release, such as
# https://hex.pm/api/packages/libtmux/releases/0.1.1. The release must answer
# 200 with JSON that names VERSION and declares no requirement, because the core
# has no runtime dependency. It makes one request of at most 30 seconds.
# Exits 0 when the release matches and 1 otherwise.

defmodule CheckHexRelease do
  @moduledoc false

  @request_ms 30_000

  @doc "Whether a release document names `version` and declares no requirement."
  def release?(body, version) do
    match?(
      {:ok, %{"version" => ^version, "requirements" => requirements}} when requirements == %{},
      JSON.decode(body)
    )
  end

  def main([url, version]) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    case request(url) do
      {:ok, 200, body} ->
        if release?(body, version),
          do: IO.puts("Hex release #{version} declares no requirement"),
          else: fail("Hex release is not version #{version} with no requirements: #{url}")

      {:ok, status, _body} ->
        fail("Hex release request failed: HTTP #{status}")

      {:error, reason} ->
        fail("Hex release request failed: #{inspect(reason, limit: 4)}")
    end
  end

  def main(_arguments), do: fail("usage: elixir check_hex_release.exs URL VERSION")

  defp request(url) do
    options = [timeout: @request_ms, connect_timeout: @request_ms, autoredirect: true] ++ tls(url)
    headers = [{~c"accept", ~c"application/json"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
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

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: CheckHexRelease.main(System.argv())
