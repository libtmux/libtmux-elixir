"""The README, the implementation notes and the contributor guide state the support table."""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import ci_plan

MANIFEST = ci_plan.load()
NAMES = [entry["tmux"] for entry in MANIFEST["required_linux"]]


def joined(names):
    return ", ".join(names[:-1]) + f" and {names[-1]}"


def problems(manifest, readme, implementation, contributing):
    """Name each way a document disagrees with the manifest."""
    names = [entry["tmux"] for entry in manifest["required_linux"]]
    edges = ci_plan.edge_versions(names)
    found = []
    flat = {"README": " ".join(readme.split()), "implementation notes": " ".join(implementation.split()),
            "contributor guide": " ".join(contributing.split())}
    if f"tested with {joined(names)};" not in flat["README"]:
        found.append("the README does not list the manifest's tmux cells")
    if f"a push tests {joined(edges)}" not in flat["README"]:
        found.append("the README does not name the edges a push tests")
    if f"Required Linux cells are tmux {joined(names)} on" not in flat["implementation notes"]:
        found.append("the implementation notes do not list the manifest's tmux cells")
    if f"run the oldest and newest, {joined(edges)}," not in flat["implementation notes"]:
        found.append("the implementation notes do not name the edges a push runs")
    if f"oldest and newest listed tmux release ({joined(edges)})" not in flat["contributor guide"]:
        found.append("the contributor guide does not name the edges a push plans")
    if f"| tmux | {manifest['tmux_minimum']} minimum;" not in flat["README"]:
        found.append("the README does not state the manifest's tmux minimum")
    return found


class Documents(unittest.TestCase):
    def setUp(self):
        self.readme = (ROOT / "README.md").read_text()
        self.implementation = (ROOT / "docs/implementation.md").read_text()
        self.contributing = (ROOT / ".github/CONTRIBUTING.md").read_text()

    def check(self, manifest=MANIFEST, readme=None, implementation=None, contributing=None):
        return problems(manifest, readme or self.readme, implementation or self.implementation,
                        contributing or self.contributing)

    def test_the_documents_agree_with_the_manifest(self):
        self.assertEqual(self.check(), [])

    def test_a_new_release_fails_until_the_documents_move(self):
        manifest = {**MANIFEST, "required_linux": [*MANIFEST["required_linux"], {"tmux": "3.9", "source": "a" * 40}]}
        self.assertEqual(len(self.check(manifest)), 5)

    def test_a_document_that_drifts_is_reported(self):
        cases = [
            ("readme", self.readme.replace("3.3, 3.3a, 3.4 and 3.8;", "3.3, 3.4 and 3.8;"), "README does not list"),
            ("readme", self.readme.replace("a push tests 3.3 and 3.8", "a push tests 3.3 and 3.4"), "README does not name the edges"),
            ("readme", self.readme.replace("3.3 minimum", "3.3a minimum"), "README does not state the manifest's tmux minimum"),
            ("implementation", self.implementation.replace("3.3, 3.3a,\n3.4 and 3.8 on", "3.3 and 3.8 on"), "implementation notes do not list"),
            ("implementation", self.implementation.replace("3.3 and 3.8, and\na release", "3.3 and 3.4, and\na release"), "implementation notes do not name the edges"),
            ("contributing", self.contributing.replace("(3.3 and 3.8)", "(3.3a and 3.8)"), "contributor guide does not name the edges"),
        ]
        for name, text, message in cases:
            with self.subTest(message):
                self.assertNotEqual(text, {"readme": self.readme, "implementation": self.implementation,
                                           "contributing": self.contributing}[name])
                reported = self.check(**{name: text})
                self.assertTrue([each for each in reported if message in each], (message, reported))


if __name__ == "__main__":
    unittest.main()
