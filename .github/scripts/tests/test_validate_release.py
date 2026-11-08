import contextlib
import io
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import release_version
import validate_release


ROOT = Path(__file__).resolve().parents[3]


class ValidateReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        files = {
            "release.json": '{"version": "1.2.3", "build": 42}\n',
            "pubspec.yaml": (
                "version: 1.2.3+42\nflutter:\n  assets:\n    - pubspec.yaml\n"
            ),
            "CHANGELOG.md": "# Changelog\n\n## v1.2.3\n\n- Release notes\n",
            "pubspec.lock": (
                'packages:\n  flutter_rust_bridge:\n    dependency: "direct main"\n'
                '    version: "2.11.1"\n'
            ),
        }
        installer = (
            "[Setup]\nUninstallDisplayName={#MyAppName}\n[Run]\n"
            'Filename: "{app}\\{#MyAppExeName}"; '
            "Flags: nowait postinstall skipifsilent\n"
        )
        for path in ("windows/build.iss", "windows/build_arm64.iss"):
            files[path] = installer
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        paths = patch.multiple(
            release_version,
            CONFIG_PATH=self.root / "release.json",
            PUBSPEC_PATH=self.root / "pubspec.yaml",
            CHANGELOG_PATH=self.root / "CHANGELOG.md",
        )
        paths.start()
        self.addCleanup(paths.stop)
        reader = patch.object(
            validate_release,
            "read_text",
            side_effect=lambda path: (self.root / path).read_text(encoding="utf-8"),
        )
        reader.start()
        self.addCleanup(reader.stop)

    def invoke(self, *args, ref="refs/heads/main", ref_type="branch", status=None):
        prefix = "refs/tags/" if ref_type == "tag" else "refs/heads/"
        env = {
            "GITHUB_REF": ref,
            "GITHUB_REF_NAME": ref.removeprefix(prefix),
            "GITHUB_REF_TYPE": ref_type,
        }
        output = io.StringIO()
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(sys, "argv", ["validate_release.py", *args]),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            if status is None:
                validate_release.main()
            else:
                with self.assertRaises(SystemExit) as error:
                    validate_release.main()
                self.assertEqual(error.exception.code, status)
        return output.getvalue()

    def test_branch_build_uses_configured_version_not_branch_name(self):
        for branch in ("main", "feature/reader", "v9.9.9"):
            with self.subTest(branch=branch):
                output = self.invoke("--build-only", ref=f"refs/heads/{branch}")
                self.assertIn("Build metadata for v1.2.3 is valid", output)

    def test_branch_requires_explicit_build_only_mode(self):
        output = self.invoke(status=1)
        self.assertIn("got 'main'", output)

    def test_release_tag_is_checked_by_default(self):
        output = self.invoke(ref="refs/tags/v1.2.3", ref_type="tag")
        self.assertIn("Release metadata for v1.2.3 is valid", output)

    def test_release_rejects_malformed_and_mismatched_tags(self):
        for tag in ("main", "v9.9.9", "v1.2.3-rc.1"):
            with self.subTest(tag=tag):
                output = self.invoke(ref=f"refs/tags/{tag}", ref_type="tag", status=1)
                self.assertIn("::error::", output)

    def test_tag_build_cannot_opt_out_of_tag_validation(self):
        for tag in ("v1.2.3", "v9.9.9"):
            with self.subTest(tag=tag):
                output = self.invoke(
                    "--build-only", ref=f"refs/tags/{tag}", ref_type="tag", status=1
                )
                self.assertIn("Tag builds must validate the release tag", output)

    def test_tag_ref_is_guarded_even_without_tag_ref_type(self):
        self.invoke("--build-only", ref="refs/tags/v9.9.9", ref_type="", status=1)

    def test_explicit_tag_remains_available_for_local_validation(self):
        self.assertIn("Release metadata", self.invoke("--tag", "v1.2.3"))

    def test_build_mode_and_explicit_tag_are_mutually_exclusive(self):
        self.invoke("--build-only", "--tag", "v1.2.3", status=2)

    def test_branch_build_cannot_write_release_notes(self):
        target = self.root / "notes.md"
        self.invoke("--build-only", "--write-notes", str(target), status=2)
        self.assertFalse(target.exists())

    def test_tag_build_can_write_validated_release_notes(self):
        target = self.root / "notes.md"
        self.invoke(
            "--write-notes", str(target), ref="refs/tags/v1.2.3", ref_type="tag"
        )
        self.assertEqual(target.read_text(encoding="utf-8"), "- Release notes\n")

    def test_repository_install_guides_link_to_the_release_tag(self):
        policy = self.root / '.github/harmonyos-next.json'
        policy.parent.mkdir()
        policy.write_text('{"guide_delivery": "repository"}', encoding='utf-8')
        for language in ('zh', 'en'):
            guide = self.root / f'doc/distribution/harmonyos-reader.{language}.md'
            guide.parent.mkdir(parents=True, exist_ok=True)
            guide.write_text('# Installation\n', encoding='utf-8')
        target = self.root / 'notes.md'
        self.invoke('--write-notes', str(target), ref='refs/tags/v1.2.3', ref_type='tag')
        notes = target.read_text(encoding='utf-8')
        self.assertIn('- Release notes', notes)
        for language in ('zh', 'en'):
            self.assertIn(f'/blob/v1.2.3/doc/distribution/harmonyos-reader.{language}.md', notes)
        self.assertNotIn('/blob/main/', notes)
        self.assertNotIn('harmonyos-install.', notes)
        guide.write_text(' \n', encoding='utf-8')
        target.unlink()
        self.invoke('--write-notes', str(target), ref='refs/tags/v1.2.3', ref_type='tag', status=1)
        self.assertFalse(target.exists())

    def test_branch_mode_keeps_all_metadata_guards(self):
        invalid = {
            "release.json": '{}\n',
            "pubspec.yaml": "version: 9.9.9+42\n",
            "CHANGELOG.md": "## v1.2.3\n\n",
            "pubspec.lock": "packages: {}\n",
            "windows/build.iss": "[Setup]\n",
            "windows/build_arm64.iss": "[Setup]\n",
        }
        for path, text in invalid.items():
            with self.subTest(path=path):
                target = self.root / path
                original = target.read_bytes()
                try:
                    target.write_text(text, encoding="utf-8")
                    self.invoke("--build-only", status=1)
                finally:
                    target.write_bytes(original)

    def test_complete_build_keeps_branch_and_release_paths_separate(self):
        workflow = (ROOT / ".github/workflows/main.yml").read_text(encoding="utf-8")
        metadata = re.search(
            r"^  Release_Metadata:\n(?P<body>.*?)(?=^  \w+:)",
            workflow,
            re.MULTILINE | re.DOTALL,
        ).group("body")
        self.assertRegex(
            metadata,
            r"if: github\.ref_type == 'tag'\n"
            r"\s+run: python3 \.github/scripts/validate_release\.py\n",
        )
        self.assertRegex(
            metadata,
            r"if: github\.ref_type != 'tag'\n"
            r"\s+run: python3 \.github/scripts/validate_release\.py --build-only\n",
        )
        release = workflow.split("\n  Release:\n", 1)[1]
        self.assertIn(
            "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')",
            release,
        )
        self.assertIn(
            "run: python3 .github/scripts/validate_release.py --write-notes", release
        )
        self.assertNotIn("--build-only", release)


if __name__ == "__main__":
    unittest.main()
