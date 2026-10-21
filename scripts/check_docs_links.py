"""Check local files and HTML fragments in a rendered ExDoc site, without network I/O."""

from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.identifiers = set()
        self.links = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if "id" in attributes:
            self.identifiers.add(attributes["id"])
        if tag == "a" and "name" in attributes:
            self.identifiers.add(attributes["name"])
        for name in ("href", "src"):
            if name in attributes:
                self.links.append((tag, name, attributes[name]))
        if "srcset" in attributes:
            self.links.extend(
                (tag, "srcset", part.strip().split()[0])
                for part in attributes["srcset"].split(",")
            )


root = Path(sys.argv[1] if len(sys.argv) == 2 else "doc").resolve()
pages = {path: Page(path) for path in root.rglob("*.html")}
if not pages:
    raise SystemExit("no rendered HTML documentation found")

failures = []
checked = 0
optional_catalogues = 0
for path, page in pages.items():
    for tag, attribute, link in page.links:
        uri = urlsplit(link)
        if uri.scheme or uri.netloc:
            continue
        # ExDoc loads this optional host-provided version catalogue on every page.
        if tag == "script" and attribute == "src" and link == "docs_config.js":
            if not (path.parent / link).exists():
                optional_catalogues += 1
                continue
        checked += 1
        target = (path.parent / unquote(uri.path)).resolve() if uri.path else path
        if target.is_dir():
            target = target / "index.html"
        if not target.is_relative_to(root) or not target.is_file():
            failures.append((str(path.relative_to(root)), link, "missing local file"))
        elif uri.fragment and target.suffix == ".html":
            if unquote(uri.fragment) not in pages[target].identifiers:
                failures.append((str(path.relative_to(root)), link, "missing HTML fragment"))

for path, link, reason in failures:
    print(f"{path}: {link}: {reason}")
print(
    f"{len(pages)} pages, {checked} local references, {len(failures)} broken; "
    f"{optional_catalogues} optional ExDoc version catalogues absent"
)
raise SystemExit(bool(failures))
