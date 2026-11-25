import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/build.yml"


def step_script(name):
    workflow = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"^      - name: {re.escape(name)}\n        run: \|\n"
        r"(?P<body>(?:          [^\n]*\n)+)",
        workflow,
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError(f"Missing workflow step: {name}")
    return "\n".join(line[10:] for line in match.group("body").splitlines())


class IosReleaseMetadataTests(unittest.TestCase):
    def test_apple_supported_languages_match_the_app_registry(self):
        registry = (ROOT / "lib/foundation/app_language.dart").read_text(encoding="utf-8")
        preferences = re.findall(r"\b\w+\(\s*'([a-z]{2}-[A-Z]{2})'", registry)
        self.assertTrue(preferences)
        scripts = {"zh-CN": "zh-Hans", "zh-TW": "zh-Hant"}
        expected = {scripts.get(value, value.split("-")[0]) for value in preferences}
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                info = plistlib.loads((ROOT / platform / "Runner/Info.plist").read_bytes())
                languages = info["CFBundleLocalizations"]
                self.assertEqual(set(languages), expected)
                self.assertEqual(len(languages), len(expected))

    def test_native_version_override_does_not_rewrite_bundled_pubspec(self):
        script = step_script("构建 iOS 应用")
        self.assertIn('--build-name "$IOS_VERSION"', script)
        self.assertIn('--build-number "$IOS_BUILD"', script)
        self.assertNotIn("pubspec.yaml.release", script)
        self.assertNotIn("perl -0pi", script)
        self.assertNotIn("sed -i", script)

    def test_actual_bundle_is_checked_for_native_and_prerelease_versions(self):
        script = step_script("校验 iOS 原生版本与应用更新渠道")
        self.assertIn("Print :CFBundleShortVersionString", script)
        self.assertIn("Print :CFBundleVersion", script)
        self.assertIn("App.framework/flutter_assets/pubspec.yaml", script)
        self.assertIn('test "$BUNDLED_VERSION" = "$APP_VERSION"', script)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX bash")
    def test_build_step_preserves_rc_assets_and_passes_numeric_native_version(self):
        script = step_script("构建 iOS 应用")
        fixtures = (
            ("1.18.0-rc.1+229", "1.18.0", "229"),
            ("1.18.0+230", "1.18.0", "230"),
            ("1.18.0-rc.2", "1.18.0", "1"),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            flutter = root / "flutter"
            flutter.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE_ARGS"\n',
                encoding="utf-8",
            )
            flutter.chmod(0o755)
            captured = root / "args.txt"
            environment = {
                **os.environ,
                "PATH": str(root) + os.pathsep + os.environ.get("PATH", ""),
                "CAPTURE_ARGS": str(captured),
            }
            pubspec = root / "pubspec.yaml"
            for version, native_version, build in fixtures:
                for newline in ("\n", "\r\n"):
                    with self.subTest(version=version, newline=repr(newline)):
                        original = f"name: fixture{newline}version: {version}{newline}".encode()
                        pubspec.write_bytes(original)
                        subprocess.run(
                            ["bash", "-e", "-c", script],
                            cwd=root,
                            env=environment,
                            check=True,
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(pubspec.read_bytes(), original)
                        self.assertEqual(
                            captured.read_text(encoding="utf-8").splitlines(),
                            [
                                "build", "ios", "--release", "--no-codesign",
                                "--build-name", native_version, "--build-number", build,
                            ],
                        )


if __name__ == "__main__":
    unittest.main()
