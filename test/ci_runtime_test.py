"""The runtime check names the profiles it accepts, and the custom one asserts nothing."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(shutil.which("elixir"), "needs the Elixir the job installs")
class RuntimeProfiles(unittest.TestCase):
    def check(self, *arguments):
        return subprocess.run(["elixir", "scripts/check_runtime.exs", *arguments], cwd=ROOT,
                              capture_output=True, text=True)

    def test_the_custom_profile_prints_the_runtime_identity_and_asserts_nothing(self):
        result = self.check("custom")
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = json.loads(result.stdout)
        self.assertEqual(identity["profile"], "custom")
        self.assertEqual(set(identity), {"profile", "elixir", "otp", "compiled_otp"})

    def test_an_unknown_profile_is_refused(self):
        result = self.check("everything")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected reference, tracking or custom", result.stderr)

    def test_a_missing_profile_is_refused(self):
        self.assertNotEqual(self.check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
