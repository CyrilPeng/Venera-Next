import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from validate_release import validate_windows_installer_metadata


class WindowsInstallerTest(unittest.TestCase):
    def setUp(self):
        self.scripts = {
            path: (ROOT / path).read_text(encoding="utf-8")
            for path in ("windows/build.iss", "windows/build_arm64.iss")
        }

    def validate(self):
        with patch("validate_release.read_text", side_effect=self.scripts.__getitem__):
            with contextlib.redirect_stdout(io.StringIO()):
                validate_windows_installer_metadata()

    def test_both_installers_preserve_metadata_and_skip_silent_launch(self):
        self.validate()

    def test_rejects_missing_skipifsilent_on_either_architecture(self):
        for path, original in list(self.scripts.items()):
            with self.subTest(path=path):
                self.scripts[path] = original.replace(" skipifsilent", "")
                with self.assertRaises(SystemExit):
                    self.validate()
                self.scripts[path] = original

    def test_flag_in_comment_does_not_satisfy_requirement(self):
        path = "windows/build.iss"
        self.scripts[path] = self.scripts[path].replace(
            "skipifsilent", "; skipifsilent"
        )
        with self.assertRaises(SystemExit):
            self.validate()

    def test_preserves_interactive_launch_option(self):
        path = "windows/build.iss"
        self.scripts[path] = self.scripts[path].replace(" postinstall", "")
        with self.assertRaises(SystemExit):
            self.validate()

    def test_rejects_missing_launch_entry(self):
        path = "windows/build.iss"
        self.scripts[path] = self.scripts[path].split("[Run]")[0]
        with self.assertRaises(SystemExit):
            self.validate()

    def test_rejects_version_in_display_name(self):
        path = "windows/build.iss"
        self.scripts[path] = self.scripts[path].replace(
            "UninstallDisplayName={#MyAppName}",
            "UninstallDisplayName={#MyAppName} {#MyAppVersion}",
        )
        with self.assertRaises(SystemExit):
            self.validate()


if __name__ == "__main__":
    unittest.main()
