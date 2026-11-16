# Checks that a pull request is closed, then deletes its documentation preview.
#
# Usage:
#   elixir scripts/docs_preview_cleanup/docs_preview_cleanup.exs eligibility
#       --repository OWNER/NAME --pr NUMBER --github-output FILE
#   elixir scripts/docs_preview_cleanup/docs_preview_cleanup.exs delete
#       --bucket BUCKET --pr NUMBER
#
# `eligibility` reads the pull request with `gh api`, which needs GH_TOKEN, and
# appends `should_cleanup=true` to the output file when the pull request is
# closed. It writes `should_cleanup=false` first, so a failed check leaves the
# cleanup off. A closed event can be rerun after the pull request reopens, which
# is why the state is read again. `delete` removes the Elixir preview under the
# docs bucket with `aws s3 rm`. Both exit 1 when the number is not a positive
# integer, and `eligibility` exits 1 when the response is not the pull request
# asked for or its state is neither open nor closed.

defmodule DocsPreviewCleanup do
  @moduledoc false

  defmodule CleanupError do
    defexception [:message]
  end

  @doc "Refuses a pull request number that is not a positive decimal integer."
  def pull_request_number!(pr) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, pr),
      do: String.to_integer(pr),
      else: fail("pull request number must be numeric")
  end

  @doc """
  Whether the pull request in a GitHub API response is closed.

  It refuses a response that is not an object, names another number, or has a
  state other than open or closed.
  """
  def eligible?(response, pr) do
    number = pull_request_number!(pr)

    case JSON.decode(response) do
      {:ok, %{"number" => ^number, "state" => state}} when state in ["open", "closed"] ->
        state == "closed"

      _other ->
        fail("invalid current pull request response")
    end
  end

  @doc "The S3 prefix that holds the preview of one pull request."
  def preview_prefix(bucket, pr) do
    _ = pull_request_number!(pr)
    "s3://#{bucket}/en/elixir/pr-#{pr}/"
  end

  @options [repository: :string, pr: :string, github_output: :string, bucket: :string]

  def main([action | arguments]) when action in ["eligibility", "delete"] do
    {options, [], []} = OptionParser.parse(arguments, strict: @options)
    run(action, options)
  rescue
    error in CleanupError ->
      IO.puts(:stderr, error.message)
      System.halt(1)
  end

  def main(_arguments) do
    IO.puts(
      :stderr,
      "usage: elixir scripts/docs_preview_cleanup/docs_preview_cleanup.exs eligibility|delete [options]"
    )

    System.halt(2)
  end

  defp run("eligibility", options) do
    repository = option!(options, :repository)
    pr = option!(options, :pr)
    output = option!(options, :github_output)
    File.write!(output, "should_cleanup=false\n", [:append])
    _ = pull_request_number!(pr)

    {response, status} =
      System.cmd(executable!("gh"), ["api", "--method", "GET", "repos/#{repository}/pulls/#{pr}"])

    if status != 0, do: System.halt(status)
    File.write!(output, "should_cleanup=#{eligible?(response, pr)}\n", [:append])
  end

  defp run("delete", options) do
    prefix = preview_prefix(option!(options, :bucket), option!(options, :pr))

    {_output, status} =
      System.cmd(executable!("aws"), ["s3", "rm", prefix, "--recursive"],
        into: IO.stream(:stdio, :line)
      )

    System.halt(status)
  end

  defp option!(options, key),
    do: options[key] || fail("--#{String.replace("#{key}", "_", "-")} is required")

  defp executable!(name), do: System.find_executable(name) || fail("#{name} is not installed")

  defp fail(message), do: raise(CleanupError, message)
end

if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: DocsPreviewCleanup.main(System.argv())
