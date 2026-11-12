"""Prove the release check refuses a package that has lost its changelog.

Each rule has a deliberate break on a copy of the real tree: the file deleted,
its Unreleased section dropped, another package's name written over its own,
or its `files` entry removed. The check has to report that break and name the
file. A tree that is not broken has to pass, or the breaks prove nothing.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "check_release.exs"
ELIXIR = shutil.which("elixir")
VERSION = re.search(r'version: "([^"]+)"', (ROOT / "mix.exs").read_text()).group(1)


def copy_tree(destination):
    """Copy what the release check reads: the Mix project and its changelog."""
    shutil.copytree(ROOT / "mix_tasks", destination / "mix_tasks")
    for name in ["mix.exs", "CHANGELOG.md"]:
        shutil.copy(ROOT / name, destination / name)


def release_check(root):
    """Run the release check for the current version in root; return (status, output)."""
    run = subprocess.run(
        [ELIXIR, str(SCRIPT), f"v{VERSION}"],
        cwd=root, capture_output=True, text=True, timeout=120, check=False)
    return run.returncode, run.stdout + run.stderr


class ChangelogReleaseCheck(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(ELIXIR, "elixir is required")
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.root = Path(self._directory.name)
        copy_tree(self.root)

    def refused(self, fragment):
        status, output = release_check(self.root)
        self.assertNotEqual(status, 0, output)
        self.assertIn(fragment, output)

    def test_the_tree_passes(self):
        status, output = release_check(self.root)
        self.assertEqual(status, 0, output)

    def test_a_missing_changelog_is_refused(self):
        (self.root / "CHANGELOG.md").unlink()
        self.refused("CHANGELOG.md: libtmux has no changelog")

    def test_a_missing_unreleased_section_is_refused(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text().replace("## Unreleased\n", ""))
        self.refused('CHANGELOG.md: has no "## Unreleased" section')

    def test_an_unreleased_heading_inside_a_fence_does_not_count(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text().replace("## Unreleased\n", "```markdown\n## Unreleased\n```\n"))
        self.refused('CHANGELOG.md: has no "## Unreleased" section')

    def test_an_unreleased_heading_inside_a_tilde_or_longer_fence_does_not_count(self):
        path = self.root / "CHANGELOG.md"
        text = path.read_text()
        # A longer fence is not closed by a shorter line inside it; a tilde
        # fence holds the heading with nothing else to hide it.
        for fence, inner in (("~~~", ""), ("````", "```\n")):
            with self.subTest(fence=fence):
                path.write_text(text.replace("## Unreleased\n", f"{fence}markdown\n{inner}## Unreleased\n{fence}\n"))
                self.refused('CHANGELOG.md: has no "## Unreleased" section')

    def test_a_closing_fence_with_an_info_string_does_not_close(self):
        path = self.root / "CHANGELOG.md"
        text = path.read_text().replace("## Unreleased\n", "```markdown\n```js\n## Unreleased\n```\n")
        path.write_text(text)
        self.refused('CHANGELOG.md: has no "## Unreleased" section')

    def test_another_packages_name_over_the_opening_sentence_is_refused(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text().replace("Notable changes to `libtmux`.", "Notable changes to `another`."))
        self.refused("CHANGELOG.md: is the changelog of another, not libtmux")

    def test_a_changelog_whose_opening_sentence_is_not_at_the_top_is_refused(self):
        path = self.root / "CHANGELOG.md"
        text = path.read_text().replace("# Changelog\n\n", "# Changelog\n\nSomething else first.\n\n")
        path.write_text(text)
        self.refused('CHANGELOG.md: does not open with "Notable changes to `libtmux`."')

    def test_a_changelog_without_the_opening_sentence_is_refused(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(re.sub(r"Notable changes to `[^`]+`\.\n\n", "", path.read_text()))
        self.refused('CHANGELOG.md: does not open with "Notable changes to `libtmux`."')

    def test_a_files_pattern_that_matches_the_changelog_ships_it(self):
        manifest = self.root / "mix.exs"
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md"', '"CHANGELOG*"'))
        status, output = release_check(self.root)
        self.assertEqual(status, 0, output)

    def test_an_omitted_files_list_is_hexs_default(self):
        manifest = self.root / "mix.exs"
        text = re.sub(r",\s*files: \[[^\]]*\]", "", manifest.read_text())
        self.assertNotIn("files:", text)
        manifest.write_text(text)
        status, output = release_check(self.root)
        self.assertEqual(status, 0, output)

    def test_a_nested_changelog_is_not_the_packages_changelog(self):
        manifest = self.root / "mix.exs"
        (self.root / "docs").mkdir()
        (self.root / "docs" / "CHANGELOG.md").write_text("nested\n")
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md"', '"docs/CHANGELOG.md"'))
        self.refused("mix.exs: `files` does not include CHANGELOG.md")

    def test_a_missing_changelog_is_reported_once(self):
        (self.root / "CHANGELOG.md").unlink()
        status, output = release_check(self.root)
        self.assertNotEqual(status, 0, output)
        self.assertNotIn("does not include", output)

    def test_a_manifest_that_does_not_ship_the_changelog_is_refused(self):
        manifest = self.root / "mix.exs"
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md",', ""))
        self.refused("mix.exs: `files` does not include CHANGELOG.md")


if __name__ == "__main__":
    unittest.main()
