# Checks the local files and HTML fragments that a rendered ExDoc site links
# to, without any network I/O.
#
# Usage: elixir scripts/check_docs_links/check_docs_links.exs [DIRECTORY]
#
# DIRECTORY defaults to `doc`. Exits 1 and lists each broken link when a local
# target or fragment is missing. Installs the HTML parser Floki on first run.

Mix.install([{:floki, "~> 0.38.4"}])

defmodule DocsLinks do
  @moduledoc false

  # ExDoc loads this optional host-provided version catalogue on every page.
  @catalogue "docs_config.js"

  def main(arguments) do
    root = arguments |> List.first("doc") |> Path.expand()

    case check(root) do
      {:error, :no_pages} ->
        IO.puts(:stderr, "no rendered HTML documentation found")
        System.halt(1)

      {:ok, result} ->
        Enum.each(report(result), &IO.puts/1)
        if result.failures != [], do: System.halt(1)
    end
  end

  @doc "Checks every page under `root`; returns the counts and each broken link."
  def check(root) do
    pages = load_pages(root)

    if pages == %{} do
      {:error, :no_pages}
    else
      {failures, checked, absent} =
        Enum.reduce(pages, {[], 0, 0}, fn {path, page}, acc ->
          Enum.reduce(page.links, acc, &check_link(&1, path, root, pages, &2))
        end)

      {:ok,
       %{
         root: root,
         pages: map_size(pages),
         checked: checked,
         absent: absent,
         failures: Enum.reverse(failures)
       }}
    end
  end

  @doc "The report lines: one per broken link, then the totals."
  def report(result) do
    broken =
      for {path, link, reason} <- result.failures,
          do: "#{Path.relative_to(path, result.root)}: #{link}: #{reason}"

    broken ++
      [
        "#{result.pages} pages, #{result.checked} local references, #{length(result.failures)} broken; " <>
          "#{result.absent} optional ExDoc version catalogues absent"
      ]
  end

  def load_pages(root) do
    root
    |> Path.join("**/*.html")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.expand(path), parse(File.read!(path))} end)
  end

  @doc "The ids and the `{tag, attribute, link}` references of one page."
  def parse(html) do
    html
    |> Floki.parse_document!()
    |> walk(%{ids: MapSet.new(), links: []})
    |> then(&%{&1 | links: Enum.reverse(&1.links)})
  end

  defp walk(nodes, page) when is_list(nodes), do: Enum.reduce(nodes, page, &walk/2)

  defp walk({tag, attributes, children}, page) when is_binary(tag) do
    page
    |> ids(tag, attributes)
    |> links(tag, attributes)
    |> then(&walk(children, &1))
  end

  defp walk(_other, page), do: page

  defp ids(page, tag, attributes) do
    named = for {"id", value} <- attributes, do: value
    anchors = if tag == "a", do: for({"name", value} <- attributes, do: value), else: []
    %{page | ids: Enum.reduce(named ++ anchors, page.ids, &MapSet.put(&2, &1))}
  end

  defp links(page, tag, attributes) do
    direct = for {name, value} <- attributes, name in ["href", "src"], do: {tag, name, value}

    srcset =
      for {"srcset", value} <- attributes,
          part <- String.split(value, ","),
          [link | _] <- [String.split(part)],
          do: {tag, "srcset", link}

    %{page | links: Enum.reverse(direct ++ srcset) ++ page.links}
  end

  defp check_link({tag, attribute, link}, path, root, pages, {failures, checked, absent}) do
    uri = URI.parse(link)
    dir = Path.dirname(path)

    cond do
      uri.scheme != nil or uri.host != nil ->
        {failures, checked, absent}

      tag == "script" and attribute == "src" and link == @catalogue and
          not File.exists?(Path.join(dir, link)) ->
        {failures, checked, absent + 1}

      true ->
        target = target(uri, path, dir)

        {[] |> missing(target, root, uri, pages, path, link) |> Kernel.++(failures), checked + 1,
         absent}
    end
  end

  defp target(%URI{path: path}, page, dir) do
    target = if path in [nil, ""], do: page, else: Path.expand(URI.decode(path), dir)
    if File.dir?(target), do: Path.join(target, "index.html"), else: target
  end

  defp missing(found, target, root, uri, pages, path, link) do
    cond do
      not inside?(target, root) or not File.regular?(target) ->
        [{path, link, "missing local file"} | found]

      uri.fragment not in [nil, ""] and Path.extname(target) == ".html" and
          not MapSet.member?(pages[target].ids, URI.decode(uri.fragment)) ->
        [{path, link, "missing HTML fragment"} | found]

      true ->
        found
    end
  end

  defp inside?(target, root), do: target == root or String.starts_with?(target, root <> "/")
end

if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: DocsLinks.main(System.argv())
