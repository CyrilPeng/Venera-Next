import importlib.util
import itertools
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "release_version",
    Path(__file__).resolve().parents[1] / "release_version.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.config_path = root / "release.json"
        self.pubspec_path = root / "pubspec.yaml"
        self.changelog_path = root / "CHANGELOG.md"
        self.config = {"version": "1.2.3-rc.1", "build": 42}
        paths = patch.multiple(
            MODULE,
            CONFIG_PATH=self.config_path,
            PUBSPEC_PATH=self.pubspec_path,
            CHANGELOG_PATH=self.changelog_path,
        )
        paths.start()
        self.addCleanup(paths.stop)

    def write(self, path, text, newline="\n", bom=False):
        data = text.replace("\n", newline).encode("utf-8")
        if bom:
            data = b"\xef\xbb\xbf" + data
        path.write_bytes(data)
        return data

    def synchronized_files(self, newline="\n", bom=False):
        self.write(self.config_path, json.dumps(self.config, indent=2), newline, bom)
        self.write(
            self.pubspec_path,
            "name: fixture\nversion: 1.2.3-rc.1+42\nflutter:\n"
            "  assets:\n    - pubspec.yaml\n",
            newline,
            bom,
        )
        self.write(
            self.changelog_path,
            "# Changelog\n\n## v1.2.3-rc.1\n\n- 更新说明\n",
            newline,
            bom,
        )

    def test_check_and_noop_sync_accept_lf_crlf_and_bom(self):
        for newline, bom in itertools.product(("\n", "\r\n"), (False, True)):
            with self.subTest(newline=newline, bom=bom):
                self.synchronized_files(newline, bom)
                paths = (self.config_path, self.pubspec_path, self.changelog_path)
                before = [path.read_bytes() for path in paths]
                MODULE.check_release_files("v1.2.3-rc.1")
                self.assertFalse(MODULE.sync_pubspec(self.config))
                self.assertFalse(MODULE.sync_changelog_heading(self.config))
                self.assertEqual([path.read_bytes() for path in paths], before)

    def test_pubspec_sync_preserves_bom_and_every_line_ending(self):
        for newline, bom, ending in itertools.product(
            ("\n", "\r\n"), (False, True), ("", "\n# footer\n")
        ):
            with self.subTest(newline=newline, bom=bom, ending=ending):
                before = self.write(
                    self.pubspec_path,
                    "# 配置\nversion: 1.0.0+1" + ending,
                    newline,
                    bom,
                )
                self.assertTrue(MODULE.sync_pubspec(self.config))
                self.assertEqual(
                    self.pubspec_path.read_bytes(),
                    before.replace(b"version: 1.0.0+1", b"version: 1.2.3-rc.1+42"),
                )
                self.assertFalse(MODULE.sync_pubspec(self.config))

    def test_changelog_sync_preserves_bom_and_every_line_ending(self):
        for newline, bom, label, ending in itertools.product(
            ("\n", "\r\n"), (False, True), ("Unreleased", "未发布"), ("", "\n- 内容\n")
        ):
            with self.subTest(newline=newline, bom=bom, label=label, ending=ending):
                heading = f"## {label}"
                before = self.write(
                    self.changelog_path, "# 更新记录\n\n" + heading + ending, newline, bom
                )
                self.assertTrue(MODULE.sync_changelog_heading(self.config))
                self.assertEqual(
                    self.changelog_path.read_bytes(),
                    before.replace(heading.encode("utf-8"), b"## v1.2.3-rc.1"),
                )
                self.assertFalse(MODULE.sync_changelog_heading(self.config))

    def test_existing_release_does_not_replace_unreleased_heading(self):
        before = self.write(
            self.changelog_path,
            "# Changelog\n## Unreleased\n- Next\n## v1.2.3-rc.1\n- Released\n",
            "\r\n",
            True,
        )
        self.assertFalse(MODULE.sync_changelog_heading(self.config))
        self.assertEqual(self.changelog_path.read_bytes(), before)

    def test_crlf_check_still_rejects_mismatches(self):
        self.synchronized_files("\r\n", True)
        with self.assertRaisesRegex(MODULE.ReleaseVersionError, "tag .* does not match"):
            MODULE.check_release_files("v1.2.3")
        self.pubspec_path.write_bytes(
            self.pubspec_path.read_bytes().replace(b"1.2.3-rc.1+42", b"1.2.3-rc.1+41")
        )
        with self.assertRaisesRegex(MODULE.ReleaseVersionError, "version .* does not match"):
            MODULE.check_release_files()
        self.synchronized_files("\r\n", True)
        self.changelog_path.write_bytes(
            self.changelog_path.read_bytes().replace(b"v1.2.3-rc.1", b"v1.2.3-rc.10")
        )
        with self.assertRaisesRegex(MODULE.ReleaseVersionError, "does not contain a section"):
            MODULE.check_release_files()

    def test_empty_version_and_heading_cannot_borrow_next_line(self):
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                self.write(self.pubspec_path, "version: \n1.0.0+1\n", newline)
                with self.assertRaisesRegex(MODULE.ReleaseVersionError, "version field"):
                    MODULE.sync_pubspec(self.config)
                self.write(self.changelog_path, "## \nUnreleased\n", newline)
                with self.assertRaisesRegex(MODULE.ReleaseVersionError, "must contain a section"):
                    MODULE.sync_changelog_heading(self.config)


if __name__ == "__main__":
    unittest.main()
