"""Keep every displayed program identical to its executable example."""
from pathlib import Path
import argparse
import re
import textwrap

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--write", action="store_true")
options = parser.parse_args()
pattern = re.compile(r"(<!-- example: (examples/[a-z_]+\.exs)(?:#([a-z_]+))? -->\n\n```elixir\n)(.*?)(```\n\n<!-- /example -->)", re.S)
checked = set()
for guide in [Path("README.md"), *sorted(Path("docs").glob("*.md"))]:
    def replace(match):
        source = Path(match[2])
        expected = source.read_text()
        if match[3]:
            region = re.escape(match[3])
            snippets = re.findall(rf"^[ \t]*# docs:begin {region}\n(.*?)^[ \t]*# docs:end {region}$", expected, re.M | re.S)
            if len(snippets) != 1:
                raise SystemExit(f"{source}: expected one example region {match[3]}")
            expected = textwrap.dedent(snippets[0])
        checked.add(source)
        if match[4] != expected and not options.write:
            raise SystemExit(f"{guide}: {source} drifted; run python3 scripts/check_example_docs.py --write")
        return match[1] + expected + match[5]
    original = guide.read_text()
    updated = pattern.sub(replace, original)
    if options.write and updated != original:
        guide.write_text(updated)
missing = set(Path("examples").glob("*.exs")) - checked
if missing:
    raise SystemExit(f"Examples without displayed source: {sorted(str(p) for p in missing)}")
print(f"PASS: {len(checked)} displayed programs match executable sources")
