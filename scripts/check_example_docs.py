"""Keep the first-task program identical to its executable example."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--write", action="store_true")
options = parser.parse_args()

source = Path("examples/capture_and_read.exs")
guide = Path("docs/first-task.md")
begin = f"<!-- example: {source.as_posix()} -->\n\n```elixir\n"
end = "```\n\n<!-- /example -->"
before, embedded = guide.read_text().split(begin)
current, after = embedded.split(end)
expected = source.read_text()

if options.write:
    guide.write_text(before + begin + expected + end + after)
elif current != expected:
    raise SystemExit("First-task source drifted; run python3 scripts/check_example_docs.py --write")

print("PASS: first-task program matches its executable source")
