"""Prove the release check refuses a package that has lost its changelog.

Each rule has a deliberate break on a copy of the real tree: the file deleted,
its Unreleased section dropped, another package's file pasted over it, or its
`files` entry removed. The check has to report that break and name the file.
A tree that is not broken has to pass, or the breaks prove nothing.
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
PACKAGES = sorted(path.parent.name for path in (ROOT / "packages").glob("*/mix.exs"))


def copy_tree(destination):
    """Copy what the release check reads: the Mix projects and their changelogs."""
    shutil.copytree(ROOT / "mix_tasks", destination / "mix_tasks")
    for name in ["mix.exs", "CHANGELOG.md"]:
        shutil.copy(ROOT / name, destination / name)
    for package in PACKAGES:
        (destination / "packages" / package).mkdir(parents=True)
        for name in ["mix.exs", "CHANGELOG.md"]:
            shutil.copy(ROOT / "packages" / package / name, destination / "packages" / package / name)


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

    def test_a_missing_changelog_is_refused_for_every_package(self):
        for package in PACKAGES:
            with self.subTest(package=package):
                (self.root / "packages" / package / "CHANGELOG.md").unlink()
                self.refused(f"packages/{package}/CHANGELOG.md: libtmux_{package} has no changelog")
                shutil.copy(ROOT / "packages" / package / "CHANGELOG.md",
                            self.root / "packages" / package / "CHANGELOG.md")
        (self.root / "CHANGELOG.md").unlink()
        self.refused("CHANGELOG.md: libtmux has no changelog")

    def test_a_missing_unreleased_section_is_refused(self):
        path = self.root / "packages" / "mcp" / "CHANGELOG.md"
        path.write_text(path.read_text().replace("## Unreleased\n", ""))
        self.refused('packages/mcp/CHANGELOG.md: has no "## Unreleased" section')

    def test_an_unreleased_heading_inside_a_fence_does_not_count(self):
        path = self.root / "packages" / "mcp" / "CHANGELOG.md"
        path.write_text(path.read_text().replace("## Unreleased\n", "```markdown\n## Unreleased\n```\n"))
        self.refused('packages/mcp/CHANGELOG.md: has no "## Unreleased" section')

    def test_an_unreleased_heading_inside_a_tilde_or_longer_fence_does_not_count(self):
        path = self.root / "packages" / "mcp" / "CHANGELOG.md"
        text = path.read_text()
        # A longer fence is not closed by a shorter line inside it; a tilde
        # fence holds the heading with nothing else to hide it.
        for fence, inner in (("~~~", ""), ("````", "```\n")):
            with self.subTest(fence=fence):
                path.write_text(text.replace("## Unreleased\n", f"{fence}markdown\n{inner}## Unreleased\n{fence}\n"))
                self.refused('packages/mcp/CHANGELOG.md: has no "## Unreleased" section')

    def test_a_closing_fence_with_an_info_string_does_not_close(self):
        path = self.root / "packages" / "mcp" / "CHANGELOG.md"
        text = path.read_text().replace("## Unreleased\n", "```markdown\n```js\n## Unreleased\n```\n")
        path.write_text(text)
        self.refused('packages/mcp/CHANGELOG.md: has no "## Unreleased" section')

    def test_another_packages_changelog_pasted_over_one_is_refused(self):
        shutil.copy(self.root / "CHANGELOG.md", self.root / "packages" / "workspace" / "CHANGELOG.md")
        self.refused("packages/workspace/CHANGELOG.md: is the changelog of libtmux, not libtmux_workspace")

    def test_a_changelog_whose_opening_sentence_is_not_at_the_top_is_refused(self):
        path = self.root / "packages" / "mcp" / "CHANGELOG.md"
        text = path.read_text().replace("# Changelog\n\n", "# Changelog\n\nSomething else first.\n\n")
        path.write_text(text)
        self.refused('packages/mcp/CHANGELOG.md: does not open with "Notable changes to `libtmux_mcp`."')

    def test_a_changelog_without_the_opening_sentence_is_refused(self):
        path = self.root / "packages" / "workspace" / "CHANGELOG.md"
        path.write_text(re.sub(r"Notable changes to `[^`]+`\.\n\n", "", path.read_text()))
        self.refused('packages/workspace/CHANGELOG.md: does not open with "Notable changes to `libtmux_workspace`."')

    def test_a_files_pattern_that_matches_the_changelog_ships_it(self):
        manifest = self.root / "packages" / "mcp" / "mix.exs"
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md"', '"CHANGELOG*"'))
        status, output = release_check(self.root)
        self.assertEqual(status, 0, output)

    def test_an_omitted_files_list_is_hexs_default(self):
        manifest = self.root / "packages" / "mcp" / "mix.exs"
        text = re.sub(r",\s*files: \[[^\]]*\]", "", manifest.read_text())
        self.assertNotIn("files:", text)
        manifest.write_text(text)
        status, output = release_check(self.root)
        self.assertEqual(status, 0, output)

    def test_a_nested_changelog_is_not_the_packages_changelog(self):
        manifest = self.root / "packages" / "mcp" / "mix.exs"
        (self.root / "packages" / "mcp" / "docs").mkdir()
        (self.root / "packages" / "mcp" / "docs" / "CHANGELOG.md").write_text("nested\n")
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md"', '"docs/CHANGELOG.md"'))
        self.refused("packages/mcp/mix.exs: `files` does not include CHANGELOG.md")

    def test_a_missing_changelog_is_reported_once(self):
        (self.root / "packages" / "mcp" / "CHANGELOG.md").unlink()
        status, output = release_check(self.root)
        self.assertNotEqual(status, 0, output)
        self.assertNotIn("does not include", output)

    def test_a_manifest_that_does_not_ship_the_changelog_is_refused(self):
        for package in PACKAGES:
            with self.subTest(package=package):
                manifest = self.root / "packages" / package / "mix.exs"
                text = manifest.read_text()
                manifest.write_text(text.replace('"CHANGELOG.md", ', ""))
                self.refused(f"packages/{package}/mix.exs: `files` does not include CHANGELOG.md")
                manifest.write_text(text)
        manifest = self.root / "mix.exs"
        manifest.write_text(manifest.read_text().replace('"CHANGELOG.md",', ""))
        self.refused("mix.exs: `files` does not include CHANGELOG.md")


if __name__ == "__main__":
    unittest.main()
