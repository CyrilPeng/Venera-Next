import importlib.util
import json
import os
from pathlib import Path
import shutil
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
    "GITHUB_REF": "refs/heads/main",
    "GITHUB_EVENT_NAME": "workflow_dispatch",
    "GITHUB_RUN_NUMBER": "12",
    "GITHUB_RUN_ATTEMPT": "2",
}


def manifest(metadata, abi="universal"):
    tv = metadata["flavor"] == "tv"
    label = "VeneraNext TV" if tv else "VeneraNext"
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
        self.assertEqual(metadata["build_number"], 200237)
        self.assertEqual(metadata["build_label"], "build.237")
        self.assertEqual(metadata["base_version"], "1.18.2-rc.1")
        self.assertEqual(metadata["base_build_number"], 237)

    def test_mobile_keeps_original_package_build_number_and_tag_support(self):
        env = dict(ENV, GITHUB_REF="refs/tags/v1.18.2", GITHUB_EVENT_NAME="workflow_call")
        metadata = self.metadata("mobile", env)
        self.assertEqual(metadata["package"], MODULE.PACKAGE)
        self.assertEqual(metadata["build_number"], 237)

    def test_tv_supports_main_pr_and_tag_builds_without_run_number_version_drift(self):
        for ref, event in (
            ("refs/heads/main", "workflow_dispatch"),
            ("refs/tags/v1.18.2-rc.1", "push"),
            ("refs/pull/131/merge", "pull_request"),
        ):
            env = dict(ENV, GITHUB_REF=ref, GITHUB_EVENT_NAME=event)
            env.pop("GITHUB_RUN_NUMBER")
            env.pop("GITHUB_RUN_ATTEMPT")
            with self.subTest(ref=ref):
                self.assertEqual(self.metadata(env=env)["build_number"], 200237)
        self.assertEqual(self.metadata(env=dict(ENV, GITHUB_RUN_NUMBER="99999"))["build_number"], 200237)

    def test_identity_and_version_code_bounds_are_checked(self):
        with self.assertRaises(ValueError):
            self.metadata(env=dict(ENV, GITHUB_SHA="abc123"))
        with self.assertRaises(ValueError):
            self.metadata("other")
        for build in (0, 210000000, 999999999):
            with self.subTest(build=build), self.assertRaises(ValueError):
                MODULE.build_metadata("tv", PUBSPEC.replace("+237", f"+{build}"), ENV)

    def test_tv_versioning_upgrades_existing_alpha_across_all_abis(self):
        old_maximum = (100000 + 19) * 10 + 3
        current = self.metadata()
        next_build = MODULE.build_metadata("tv", PUBSPEC.replace("+237", "+238"), ENV)
        for abi in MODULE.ABI_CODES:
            code = current["build_number"] * 10 + MODULE.ABI_CODES[abi]
            self.assertGreater(code, old_maximum)
            self.assertGreater(next_build["build_number"] * 10, code)
        gradle = (Path(__file__).resolve().parents[3] / "android/app/build.gradle").read_text()
        self.assertIn(f'versionCode = flutterVersionCode.toInteger() + {MODULE.TV_BUILD_OFFSET}', gradle)

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
            ('versionCode="2002370"', 'versionCode="2370"'),
            ('versionName="1.18.2-rc.1"', 'versionName="1.18.1"'),
            ('android:exported="true"', 'android:exported="false"'),
            (MODULE.PACKAGE + ".MainActivity", MODULE.PACKAGE + ".tv.MainActivity"),
            ('android:required="false"', 'android:required="true"'),
            ("LEANBACK_LAUNCHER", "LAUNCHER"),
            ("android.intent.action.MAIN", "android.intent.action.VIEW"),
            ('android:banner="@drawable/tv_banner"', ""),
            ("VeneraNext TV", "VeneraNext"),
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

    def verify_fixture(self, flavor="tv", fail_last=False, fingerprint=None):
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
            return "Signer #1 certificate SHA-256 digest: " + (fingerprint or MODULE.SIGNER_SHA256)

        with patch.object(MODULE, "find_tool", side_effect=lambda name, _: name), patch.object(MODULE, "run_tool", side_effect=run_tool), patch("builtins.print"):
            MODULE.verify_apks(metadata, Path("sdk"), "github-output")
        return metadata

    def test_verified_tv_artifacts_have_isolated_names_and_hash_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                metadata = self.verify_fixture()
                artifacts = Path("build/app/outputs/apk/tv/release")
                catalog = json.loads(Path("build/android-tv-manifest.json").read_text())
                self.assertEqual(catalog["revision"], metadata["revision"])
                self.assertEqual(len(catalog["apks"]), 4)
                for apk in catalog["apks"]:
                    self.assertTrue(apk["file"].startswith("VeneraNext-1.18.2-rc.1-android-tv"))
                    self.assertNotIn("alpha", apk["file"])
                    self.assertEqual(len(apk["sha256"]), 64)
                    self.assertEqual(apk["signer_sha256"], [MODULE.SIGNER_SHA256])
                    self.assertTrue((artifacts / apk["file"]).is_file())
                self.assertIn("apk_arm64_v8a=build/app/outputs/apk/tv/release/", Path("github-output").read_text())
            finally:
                os.chdir(original)

    def test_failed_verification_never_publishes_partial_tv_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                with self.assertRaises(ValueError):
                    self.verify_fixture(fail_last=True)
                self.assertFalse(Path("build/android-tv-manifest.json").exists())
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

    def test_different_signer_cannot_replace_existing_installations(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                with self.assertRaisesRegex(ValueError, "signing certificate differs"):
                    self.verify_fixture(fingerprint="b" * 64)
                self.assertFalse(Path("github-output").exists())
                self.assertFalse(Path("build/android-tv-manifest.json").exists())
            finally:
                os.chdir(original)

    def release_fixture(self):
        output = Path("outputs")
        output.mkdir()
        for flavor in ("mobile", "tv"):
            self.verify_fixture(flavor)
            shutil.copyfile(f"build/android-{flavor}-manifest.json", output / f"android-{flavor}-manifest.json")
            for apk in Path(f"build/app/outputs/apk/{flavor}/release").glob("*.apk"):
                shutil.copyfile(apk, output / apk.name)
        return output

    def test_release_requires_both_complete_flavors_and_verified_provenance(self):
        for mutation in ("none", "missing-tv", "missing-mobile", "extra", "changed-bytes", "wrong-commit", "wrong-signer", "duplicate-abi"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                original = Path.cwd()
                try:
                    os.chdir(directory)
                    output = self.release_fixture()
                    tv = output / "VeneraNext-1.18.2-rc.1-android-tv.apk"
                    if mutation == "missing-tv":
                        tv.unlink()
                    elif mutation == "missing-mobile":
                        (output / "VeneraNext-1.18.2-rc.1-android.apk").unlink()
                    elif mutation == "extra":
                        (output / "unexpected.apk").write_bytes(b"unexpected")
                    elif mutation == "changed-bytes":
                        tv.write_bytes(b"changed")
                    elif mutation in ("wrong-commit", "wrong-signer", "duplicate-abi"):
                        path = output / "android-tv-manifest.json"
                        catalog = json.loads(path.read_text())
                        if mutation == "wrong-commit":
                            catalog["revision"] = "c" * 40
                        elif mutation == "wrong-signer":
                            catalog["apks"][0]["signer_sha256"] = ["c" * 64]
                        else:
                            catalog["apks"][0] = catalog["apks"][1]
                        path.write_text(json.dumps(catalog))
                    if mutation == "none":
                        with patch("builtins.print"):
                            MODULE.verify_release(output, PUBSPEC, ENV)
                    else:
                        with self.assertRaises((ValueError, OSError)):
                            MODULE.verify_release(output, PUBSPEC, ENV)
                finally:
                    os.chdir(original)

    def test_regular_workflows_build_and_collect_both_flavors(self):
        workflows = Path(__file__).resolve().parents[2] / "workflows"
        pubspec = (workflows.parent.parent / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertNotIn("default-flavor:", pubspec, "Android flavors must not change Apple schemes")
        build = (workflows / "build.yml").read_text(encoding="utf-8")
        self.assertIn("flavor: [mobile, tv]", build)
        self.assertIn("flutter build apk --release --flavor mobile", build)
        self.assertIn("flutter build apk --release --flavor tv", build)
        self.assertNotIn("inputs.android_flavor", build)
        self.assertNotIn("--build-number", build.split("Build_Windows:")[0])
        self.assertIn("name: android-${{ matrix.flavor }}-manifest", build)
        self.assertIn("inputs.build_android && !inputs.quality_checked", build)
        release = (workflows / "main.yml").read_text(encoding="utf-8")
        self.assertIn("needs: [Release_Metadata, Quality]", release)
        self.assertIn("quality_checked: true", release)
        for pattern in ("apk-*", "tv-apk-*", "android-*-manifest"):
            self.assertIn("pattern: " + pattern, release)
        self.assertLess(release.index("android_tv_build.py verify-release"), release.index("gh release create"))
        smoke = (workflows / "pr_build.yml").read_text(encoding="utf-8")
        self.assertIn("flavor: [mobile, tv]", smoke)
        self.assertIn("needs: [changes, android, windows]", smoke)


if __name__ == "__main__":
    unittest.main()
