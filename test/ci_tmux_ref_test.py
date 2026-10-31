"""A tmux ref is validated before git sees it, then resolved to one commit."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import tmux_ref

ENVIRONMENT = {
    **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
}


def git(directory, *arguments):
    return subprocess.run(["git", "-C", str(directory), *arguments], check=True, env=ENVIRONMENT,
                          capture_output=True, text=True).stdout.strip()


class RefValidation(unittest.TestCase):
    def test_versions_tags_branches_and_full_commits_pass(self):
        for ref in ("3.6b", "next-3.9", "master", "release_3.7d", "feature/x", "a" * 40):
            with self.subTest(ref):
                self.assertEqual(tmux_ref.check_ref(ref), ref)

    def test_a_ref_that_could_reach_a_shell_or_a_git_option_is_refused(self):
        for ref in ("", "3.6b;id", "$(id)", "a b", "`id`", "x\ny", "-upload-pack=x", "a..b",
                    "topic/", "master.lock", "x" * 65):
            with self.subTest(ref):
                with self.assertRaises(ValueError):
                    tmux_ref.check_ref(ref)

    def test_an_abbreviated_commit_is_refused(self):
        for ref in ("a1b2c3d", "a" * 39):
            with self.subTest(ref):
                with self.assertRaisesRegex(ValueError, "abbreviated"):
                    tmux_ref.check_ref(ref)


class RefResolution(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="libtmux-elixir-tmux-ref-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.repository = Path(cls.temporary.name)
        git(cls.repository, "init", "-q", "--initial-branch=master")
        git(cls.repository, "commit", "-q", "--allow-empty", "-m", "first")
        cls.first = git(cls.repository, "rev-parse", "HEAD")
        git(cls.repository, "tag", "light")
        git(cls.repository, "tag", "-a", "-m", "annotated", "3.6b")
        git(cls.repository, "commit", "-q", "--allow-empty", "-m", "second")
        cls.second = git(cls.repository, "rev-parse", "HEAD")
        git(cls.repository, "branch", "topic/x")
        git(cls.repository, "branch", "shadow")
        git(cls.repository, "tag", "shadow", cls.first)

    def resolve(self, ref):
        return tmux_ref.resolve_commit(ref, repository=str(self.repository))

    def test_a_full_commit_resolves_to_itself_without_asking_the_remote(self):
        self.assertEqual(tmux_ref.resolve_commit("b" * 40, repository="/nonexistent"), "b" * 40)

    def test_a_lightweight_tag_resolves_to_its_commit(self):
        self.assertEqual(self.resolve("light"), self.first)

    def test_an_annotated_tag_resolves_to_the_commit_not_the_tag_object(self):
        self.assertNotEqual(git(self.repository, "rev-parse", "3.6b"), self.first)
        self.assertEqual(self.resolve("3.6b"), self.first)

    def test_a_branch_resolves_to_its_head(self):
        self.assertEqual(self.resolve("master"), self.second)
        self.assertEqual(self.resolve("topic/x"), self.second)

    def test_a_tag_wins_over_a_branch_of_the_same_name(self):
        self.assertEqual(self.resolve("shadow"), self.first)

    def test_an_unknown_ref_is_refused(self):
        with self.assertRaisesRegex(ValueError, "not a tag, a branch or a full commit"):
            self.resolve("nowhere")

    def test_a_ref_is_validated_before_git_runs(self):
        with self.assertRaises(ValueError):
            tmux_ref.resolve_commit("-upload-pack=x", repository=str(self.repository))


class Command(unittest.TestCase):
    def run_main(self, *arguments):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = tmux_ref.main(list(arguments))
        return status, out.getvalue(), err.getvalue()

    def test_a_full_commit_prints_alone(self):
        self.assertEqual(self.run_main("c" * 40), (0, "c" * 40 + "\n", ""))

    def test_an_unusable_ref_exits_nonzero_and_prints_nothing(self):
        status, out, err = self.run_main("-x")
        self.assertEqual((status, out), (1, ""))
        self.assertIn("not a usable git ref", err)

    def test_the_wrong_number_of_arguments_is_a_usage_error(self):
        self.assertEqual(self.run_main()[0], 2)
        self.assertEqual(self.run_main("a", "b")[0], 2)


if __name__ == "__main__":
    unittest.main()
