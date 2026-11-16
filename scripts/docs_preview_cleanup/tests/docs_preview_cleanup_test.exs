# Run with: elixir scripts/docs_preview_cleanup/tests/docs_preview_cleanup_test.exs
#
# Proves a closed pull request is eligible and an open one is not, that each
# malformed response and number is refused, and that the command line refuses a
# number before it calls gh or aws.

Code.require_file("../docs_preview_cleanup.exs", __DIR__)
ExUnit.start()

defmodule DocsPreviewCleanupTest do
  use ExUnit.Case, async: true

  @script Path.expand("../docs_preview_cleanup.exs", __DIR__)

  defp refused(message, fun) do
    error = assert_raise DocsPreviewCleanup.CleanupError, fun
    assert error.message == message
  end

  test "a closed pull request is eligible and an open one is not" do
    assert DocsPreviewCleanup.eligible?(~s({"number": 12, "state": "closed", "title": "x"}), "12")
    refute DocsPreviewCleanup.eligible?(~s({"number": 12, "state": "open"}), "12")
  end

  for {description, response} <- [
        {"an array", "[]"},
        {"null", "null"},
        {"a string", ~s("closed")},
        {"truncated JSON", "{"},
        {"an empty response", ""},
        {"another number", ~s({"number": 13, "state": "closed"})},
        {"a number as a string", ~s({"number": "12", "state": "closed"})},
        {"no number", ~s({"state": "closed"})},
        {"a state that is neither", ~s({"number": 12, "state": "merged"})},
        {"a state in another case", ~s({"number": 12, "state": "Closed"})},
        {"no state", ~s({"number": 12})}
      ] do
    test "#{description} is refused" do
      refused("invalid current pull request response", fn ->
        DocsPreviewCleanup.eligible?(unquote(response), "12")
      end)
    end
  end

  for pr <- ["", "0", "012", "abc", "12 ", "-3", "1.5"] do
    test "the pull request number #{inspect(pr)} is refused" do
      refused("pull request number must be numeric", fn ->
        DocsPreviewCleanup.eligible?(~s({"number": 12, "state": "closed"}), unquote(pr))
      end)

      refused("pull request number must be numeric", fn ->
        DocsPreviewCleanup.preview_prefix("bucket", unquote(pr))
      end)
    end
  end

  test "the preview prefix is the Elixir preview of the pull request" do
    assert DocsPreviewCleanup.preview_prefix("docs-bucket", "34") ==
             "s3://docs-bucket/en/elixir/pr-34/"
  end

  test "the command line refuses a number before it calls gh or aws" do
    output =
      Path.join(System.tmp_dir!(), "docs-preview-cleanup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(output) end)

    assert {message, 1} =
             System.cmd(
               "elixir",
               [
                 @script,
                 "eligibility",
                 "--repository",
                 "a/b",
                 "--pr",
                 "abc",
                 "--github-output",
                 output
               ],
               stderr_to_stdout: true
             )

    assert message =~ "pull request number must be numeric"
    assert File.read!(output) == "should_cleanup=false\n"

    assert {delete_message, 1} =
             System.cmd("elixir", [@script, "delete", "--bucket", "b", "--pr", "abc"],
               stderr_to_stdout: true
             )

    assert delete_message =~ "pull request number must be numeric"
  end

  test "an unknown action is a usage error" do
    assert {message, 2} = System.cmd("elixir", [@script, "remove"], stderr_to_stdout: true)
    assert message =~ "usage:"
  end
end
