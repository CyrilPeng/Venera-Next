import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from validate_release import validate_flutter_rust_bridge_lock


class BridgeLockValidationTests(unittest.TestCase):
    def validate(self, dependency="direct main", version="2.11.1", extra=""):
        lock = (
            'packages:\n  flutter_rust_bridge:\n'
            f'    dependency: "{dependency}"\n'
            '    description:\n      name: flutter_rust_bridge\n'
            '    source: hosted\n'
            f'    version: "{version}"\n{extra}'
        )
        with patch("validate_release.read_text", return_value=lock):
            with contextlib.redirect_stdout(io.StringIO()):
                validate_flutter_rust_bridge_lock()

    def test_direct_main_and_identical_override_lock_are_both_valid(self):
        for dependency in ("direct main", "direct overridden"):
            with self.subTest(dependency=dependency):
                self.validate(dependency=dependency)

    def test_wrong_version_cannot_use_neighboring_package_version(self):
        with self.assertRaises(SystemExit):
            self.validate(version="2.11.0", extra='  other:\n    version: "2.11.1"\n')

    def test_transitive_lock_does_not_satisfy_direct_dependency(self):
        with self.assertRaises(SystemExit):
            self.validate(dependency="transitive")

    def test_missing_package_is_rejected(self):
        with patch("validate_release.read_text", return_value='packages:\n  other:\n    version: "2.11.1"\n'):
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit):
                    validate_flutter_rust_bridge_lock()
