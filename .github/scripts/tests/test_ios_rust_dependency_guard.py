import re
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class IosRustDependencyGuardTests(unittest.TestCase):
    def test_libc_manifest_pin_matches_a_compatible_lock(self):
        rust = ROOT / "packages/rhttp/rust"
        manifest = tomllib.loads((rust / "Cargo.toml").read_text(encoding="utf-8"))
        lock = tomllib.loads((rust / "Cargo.lock").read_text(encoding="utf-8"))
        pin = manifest["dependencies"]["libc"]
        self.assertTrue(pin.startswith("="))
        selected = [p["version"] for p in lock["package"] if p["name"] == "libc"]
        self.assertEqual(selected, [pin[1:]])
        self.assertNotEqual(selected, ["0.2.190"])

    def test_dependabot_ignores_the_known_broken_libc_release(self):
        config = (ROOT / ".github/dependabot.yml").read_text(encoding="utf-8")
        cargo = re.search(
            r"^  - package-ecosystem: cargo\n(?P<body>.*?)(?=^  - package-ecosystem:|\Z)",
            config,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(cargo)
        self.assertRegex(
            cargo.group("body"),
            r'dependency-name: libc\n\s+versions: \["0\.2\.190"\]',
        )


if __name__ == "__main__":
    unittest.main()
