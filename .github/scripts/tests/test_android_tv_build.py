import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "android_tv_build", Path(__file__).resolve().parents[1] / "android_tv_build.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PUBSPEC = "name: venera_next\nversion: 1.18.2-rc.1+237\n"
ENV = {
    "GITHUB_SHA": "a" * 40,
    "GITHUB_REF": "refs/heads/android-tv",
    "GITHUB_EVENT_NAME": "workflow_dispatch",
    "GITHUB_RUN_NUMBER": "12",
    "GITHUB_RUN_ATTEMPT": "2",
}


def manifest(metadata, abi="universal"):
    tv = metadata["flavor"] == "tv"
    label = "VeneraNext TV Alpha" if tv else "VeneraNext"
    features = (
        '<uses-feature android:name="android.hardware.touchscreen" android:required="false"/>'
        '<uses-feature android:name="android.software.leanback" android:required="false"/>'
        if tv else ""
    )
    banner = 'android:banner="@drawable/tv_banner"' if tv else ""
    orientation = 'android:screenOrientation="landscape"' if tv else ""
    intent = (
        '<intent-filter><action android:name="android.intent.action.MAIN"/>'
        '<category android:name="android.intent.category.LEANBACK_LAUNCHER"/></intent-filter>'
        if tv else ""
    )
    code = metadata["build_number"] * 10 + MODULE.ABI_CODES[abi]
    return (
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        f'package="{metadata["package"]}" android:versionName="{metadata["base_version"]}" '
        f'android:versionCode="{code}">{features}'
        f'<application android:label="{label}" {banner}>'
        f'<activity android:name="{MODULE.PACKAGE}.MainActivity" android:exported="true" {orientation}>'
        f'{intent}</activity></application></manifest>'
    )


def write_apk(path, abi="universal", pubspec=PUBSPEC):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("assets/flutter_assets/pubspec.yaml", pubspec)
        abis = set(MODULE.ABI_CODES) - {"universal"} if abi == "universal" else {abi}
        for item in abis:
            archive.writestr(f"lib/{item}/libapp.so", b"test fixture, not an APK")


class AndroidTvBuildTest(unittest.TestCase):
    def metadata(self, flavor="tv", env=None):
        return MODULE.build_metadata(flavor, PUBSPEC, ENV if env is None else env)

    def test_tv_identity_is_independent_but_keeps_source_base_version(self):
        metadata = self.metadata()
        self.assertEqual(metadata["package"], MODULE.PACKAGE + ".tv")
        self.assertEqual(metadata["build_number"], 100012)
        self.assertEqual(metadata["build_label"], "alpha.12.2")
        self.assertEqual(metadata["base_version"], "1.18.2-rc.1")
        self.assertEqual(metadata["base_build_number"], 237)

    def test_mobile_keeps_original_package_build_number_and_tag_support(self):
        env = dict(ENV, GITHUB_REF="refs/tags/v1.18.2", GITHUB_EVENT_NAME="workflow_call")
        metadata = self.metadata("mobile", env)
        self.assertEqual(metadata["package"], MODULE.PACKAGE)
        self.assertEqual(metadata["build_number"], 237)

    def test_tv_rejects_other_branches_tags_events_and_bad_identity(self):
        invalid = [
            ("GITHUB_REF", "refs/heads/main"),
            ("GITHUB_REF", "refs/tags/android-tv"),
            ("GITHUB_EVENT_NAME", "push"),
            ("GITHUB_EVENT_NAME", "workflow_call"),
            ("GITHUB_SHA", "abc123"),
            ("GITHUB_RUN_NUMBER", "0"),
            ("GITHUB_RUN_NUMBER", "999999999"),
            ("GITHUB_RUN_ATTEMPT", "-1"),
            ("GITHUB_RUN_NUMBER", "12\noutput=injection"),
        ]
        for name, value in invalid:
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                self.metadata(env=dict(ENV, **{name: value}))
        with self.assertRaises(ValueError):
            self.metadata("other")

    def test_actual_manifest_contract_for_all_flavors_and_abis(self):
        for flavor in ("mobile", "tv"):
            metadata = self.metadata(flavor)
            for abi in MODULE.ABI_CODES:
                with self.subTest(flavor=flavor, abi=abi):
                    MODULE.validate_manifest(manifest(metadata, abi), metadata, abi)

    def test_tv_manifest_rejects_isolation_and_launcher_regressions(self):
        metadata = self.metadata()
        xml = manifest(metadata)
        mutations = [
            (metadata["package"] + '"', MODULE.PACKAGE + '"'),
            ('versionCode="1000120"', 'versionCode="2370"'),
            ('versionName="1.18.2-rc.1"', 'versionName="1.18.1"'),
            ('android:exported="true"', 'android:exported="false"'),
            (MODULE.PACKAGE + ".MainActivity", MODULE.PACKAGE + ".tv.MainActivity"),
            ('android:required="false"', 'android:required="true"'),
            ("LEANBACK_LAUNCHER", "LAUNCHER"),
            ("android.intent.action.MAIN", "android.intent.action.VIEW"),
            ('android:banner="@drawable/tv_banner"', ""),
            ("VeneraNext TV Alpha", "VeneraNext"),
            ('android:screenOrientation="landscape"', ""),
            ("<application ", '<application android:debuggable="true" '),
        ]
        for old, new in mutations:
            with self.subTest(old=old), self.assertRaises(ValueError):
                MODULE.validate_manifest(xml.replace(old, new), metadata, "universal")

    def test_compiled_landscape_enum_is_accepted_but_other_values_are_rejected(self):
        metadata = self.metadata()
        xml = manifest(metadata)
        for value in ("0", "0x0"):
            MODULE.validate_manifest(xml.replace('screenOrientation="landscape"', f'screenOrientation="{value}"'), metadata, "universal")
        for value in ("1", "portrait", "-1", "sensorLandscape"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.validate_manifest(xml.replace('screenOrientation="landscape"', f'screenOrientation="{value}"'), metadata, "universal")

    def test_mobile_manifest_rejects_tv_launcher_and_banner(self):
        metadata = self.metadata("mobile")
        tv = self.metadata()
        tv["package"] = metadata["package"]
        tv["build_number"] = metadata["build_number"]
        with self.assertRaises(ValueError):
            MODULE.validate_manifest(manifest(tv), metadata, "universal")

    def test_bundled_version_and_abis_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            write_apk(apk)
            MODULE.validate_contents(apk, self.metadata(), "universal")
            with self.assertRaises(ValueError):
                MODULE.validate_contents(apk, self.metadata(), "arm64-v8a")
            write_apk(apk, pubspec=PUBSPEC.replace("+237", "+100012"))
            with self.assertRaises(ValueError):
                MODULE.validate_contents(apk, self.metadata(), "universal")

    def test_old_and_current_sdk_certificate_formats_are_checked(self):
        fingerprint = "b" * 64
        for prefix in ("Signer #1", "V2 Signer:", "V3 Signer:", "V3.1 Signer:"):
            with self.subTest(prefix=prefix):
                self.assertEqual(
                    MODULE.signer_fingerprints(f"{prefix} certificate SHA-256 digest: {fingerprint}\n"),
                    [fingerprint],
                )
        for output in (
            "Verifies\n",
            f"Source Stamp Signer certificate SHA-256 digest: {fingerprint}\n",
            f"Signer #1 public key SHA-256 digest: {fingerprint}\n",
            "Signer #1 certificate SHA-256 digest: abcd\n",
        ):
            with self.subTest(output=output), self.assertRaises(ValueError):
                MODULE.signer_fingerprints(output)

    def verify_fixture(self, flavor="tv", fail_last=False):
        metadata = self.metadata(flavor)
        directory = Path(f"build/app/outputs/apk/{flavor}/release")
        directory.mkdir(parents=True)
        platform = "android-tv" if flavor == "tv" else "android"
        abis = {}
        for abi in MODULE.ABI_CODES:
            path = directory / f"VeneraNext-{metadata['base_version']}-{platform}{'' if abi == 'universal' else '-' + abi}.apk"
            write_apk(path, abi)
            abis[str(path)] = abi

        def run_tool(tool, *arguments):
            abi = abis[arguments[-1]]
            if tool == "apkanalyzer":
                return manifest(metadata, abi)
            if fail_last and abi == "universal":
                raise ValueError("Invalid signature fixture")
            return "Signer #1 certificate SHA-256 digest: " + "b" * 64

        with patch.object(MODULE, "find_tool", side_effect=lambda name, _: name), patch.object(MODULE, "run_tool", side_effect=run_tool), patch("builtins.print"):
            MODULE.verify_apks(metadata, Path("sdk"), "github-output")
        return metadata

    def test_verified_tv_artifacts_have_isolated_names_and_hash_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                metadata = self.verify_fixture()
                artifacts = Path("build/android-tv/artifacts")
                catalog = json.loads((artifacts / "build-manifest.json").read_text())
                self.assertEqual(catalog["revision"], metadata["revision"])
                self.assertEqual(len(catalog["apks"]), 4)
                for apk in catalog["apks"]:
                    self.assertTrue(apk["file"].startswith("VeneraNext-TV-"))
                    self.assertEqual(len(apk["sha256"]), 64)
                    self.assertEqual(apk["signer_sha256"], ["b" * 64])
                    self.assertTrue((artifacts / apk["file"]).is_file())
                self.assertIn("apk_arm64_v8a=build/android-tv/artifacts/", Path("github-output").read_text())
            finally:
                os.chdir(original)

    def test_failed_verification_never_publishes_partial_tv_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                with self.assertRaises(ValueError):
                    self.verify_fixture(fail_last=True)
                self.assertFalse(Path("build/android-tv/artifacts").exists())
                self.assertFalse(Path("github-output").exists())
            finally:
                os.chdir(original)

    def test_mobile_outputs_keep_release_collector_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                self.verify_fixture("mobile")
                self.assertFalse(Path("build/android-tv").exists())
                output = Path("github-output").read_text()
                self.assertIn("apk_universal=build/app/outputs/apk/mobile/release/", output)
            finally:
                os.chdir(original)


if __name__ == "__main__":
    unittest.main()
