# Run with: elixir scripts/check_docs_links/tests/check_docs_links_test.exs
#
# Builds small rendered sites and checks them, so each rule has a site that must
# pass and a site that must fail. One test runs the script itself.

Code.require_file("../check_docs_links.exs", __DIR__)
ExUnit.start()

defmodule CheckDocsLinksTest do
  use ExUnit.Case, async: true

  @script Path.expand("../check_docs_links.exs", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ltx-links-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp page(root, name, body) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "<!doctype html><html><body>#{body}</body></html>")
  end

  defp check(root) do
    {:ok, result} = DocsLinks.check(root)
    {result, Enum.join(DocsLinks.report(result), "\n")}
  end

  test "links, fragments, directories, images and srcset that resolve pass", %{root: root} do
    page(
      root,
      "index.html",
      ~s|<a href="a.html#top">a</a> <a href="sub/">sub</a> <a href="#here" id="here">here</a>
      <img src="logo.svg" srcset="logo.svg 1x, logo@2.svg 2x"> <a href="a.html#old">old</a>|
    )

    page(root, "a.html", ~s|<h1 id="top">a</h1><a name="old"></a>|)
    page(root, "sub/index.html", "<p>sub</p>")
    File.write!(Path.join(root, "logo.svg"), "<svg/>")
    File.write!(Path.join(root, "logo@2.svg"), "<svg/>")

    assert {%{failures: []}, output} = check(root)
    assert output =~ "3 pages, 7 local references, 0 broken"
  end

  test "external schemes and host-relative references are not checked", %{root: root} do
    page(root, "index.html", ~s|<a href="https://example.com/x">x</a> <a href="mailto:a@b.c">m</a>
      <a href="//cdn.example/x.js">cdn</a> <a href="data:text/plain,x">d</a>|)

    assert {%{failures: []}, output} = check(root)
    assert output =~ "0 local references, 0 broken"
  end

  test "a missing file is named with its page", %{root: root} do
    page(root, "index.html", ~s|<a href="missing.html">m</a>|)

    assert {%{failures: [_]}, output} = check(root)
    assert output =~ "index.html: missing.html: missing local file"
    assert output =~ "1 broken"
  end

  test "a missing fragment is reported in the page it points into", %{root: root} do
    page(root, "index.html", ~s|<a href="a.html#nope">n</a> <a href="#absent">self</a>|)
    page(root, "a.html", ~s|<h1 id="top">a</h1>|)

    assert {%{failures: [_, _]}, output} = check(root)
    assert output =~ "index.html: a.html#nope: missing HTML fragment"
    assert output =~ "index.html: #absent: missing HTML fragment"
  end

  test "a link that leaves the site is broken even when the file exists", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.html")
    File.write!(outside, "x")
    on_exit(fn -> File.rm(outside) end)
    page(root, "index.html", ~s|<a href="../#{Path.basename(outside)}">out</a>|)

    assert {%{failures: [_]}, output} = check(root)
    assert output =~ "missing local file"
  end

  test "a broken srcset candidate and image are reported", %{root: root} do
    page(root, "index.html", ~s|<img src="gone.png" srcset="also-gone.png 2x">|)

    assert {%{failures: [_, _]}, output} = check(root)
    assert output =~ "gone.png: missing local file"
    assert output =~ "also-gone.png: missing local file"
  end

  test "the optional version catalogue is counted when absent and checked when present", %{
    root: root
  } do
    page(root, "index.html", ~s|<script src="docs_config.js"></script>|)

    assert {%{failures: []}, output} = check(root)
    assert output =~ "1 optional ExDoc version catalogues absent"

    File.write!(Path.join(root, "docs_config.js"), "")
    assert {%{failures: []}, output} = check(root)
    assert output =~ "1 local references, 0 broken; 0 optional"
  end

  test "a directory with no pages is refused", %{root: root} do
    assert DocsLinks.check(root) == {:error, :no_pages}
  end

  test "the script exits 1 on a broken link and 0 on a clean site", %{root: root} do
    page(root, "index.html", ~s|<a href="missing.html">m</a>|)
    assert {output, 1} = System.cmd("elixir", [@script, root], stderr_to_stdout: true)
    assert output =~ "index.html: missing.html: missing local file"

    page(root, "index.html", ~s|<a href="index.html">self</a>|)
    assert {output, 0} = System.cmd("elixir", [@script, root], stderr_to_stdout: true)
    assert output =~ "1 pages, 1 local references, 0 broken"
  end
end
