"""Build, audit and export the complete Flutter reader source as a lab HAP."""

import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile
from pathlib import Path

from ci_build import CI, run_logged
from native_build import ROOT, digest, require_within, validate_elf
from prepare_full_app import BASE, DEPS, EXTRA_LIBRARIES, FULL_CONFIG, PROJECT
from prepare_probe import LIBRARIES
from sideload import audit_device_types


ASSET_PREFIX = "resources/rawfile/flutter_assets/"
METADATA_ASSET = ASSET_PREFIX + "assets/harmonyos-app-build.json"
TESTS = (
    "test/components/application_update_prompt_test.dart",
    "test/foundation/harmonyos_test.dart",
    "test/foundation/directory_selection_test.dart",
    "test/foundation/selection_operation_test.dart",
    "test/foundation/file_selection_test.dart",
    "test/foundation/file_selection_lifecycle_test.dart",
    "test/foundation/image_processing_test.dart",
    "test/foundation/image_processing_native_test.dart",
    "test/features/sync/app_data_archive_test.dart",
    "test/features/local_comics/import_export/cbz_compatibility_test.dart",
    "test/features/local_comics/import_export/epub_import_test.dart",
    "test/features/local_comics/import_export/comic_import_service_test.dart",
    "test/features/local_comics/import_export/import_presentation_test.dart",
    "test/features/local_comics/harmonyos_import_test.dart",
    "test/features/local_comics/local_archive_visibility_test.dart",
    "test/features/reader/platform_effects_controller_test.dart",
    "test/features/reader/platform_effects_test.dart",
    "test/features/reader/reader_exit_integration_test.dart",
    "test/features/reader/display_image_provider_test.dart",
    "test/features/reader/scroll_aware_display_image_test.dart",
)


def audit_full_hap(hap, metadata, expected_assets):
    if not hap.name.endswith("-unsigned.hap"):
        raise ValueError("Only an unsigned reader experiment may be exported")
    if (metadata.get("purpose") != "full_reader_experiment" or metadata.get("reader_integrated") is not True
            or metadata.get("runtime_verified") is not False or metadata.get("signed") is not False
            or metadata.get("entrypoint") != "lib/main.dart"):
        raise ValueError("This is not an unverified full reader experiment")
    expected = metadata["native_libraries"]
    if set(expected) != set(LIBRARIES) | set(EXTRA_LIBRARIES):
        raise ValueError("Incomplete full reader native manifest")
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError("Duplicated or corrupt HAP members")
        if any(name.startswith("/") or ".." in name.split("/") for name in names):
            raise ValueError("Unsafe HAP member")
        if json.loads(archive.read(METADATA_ASSET)) != metadata:
            raise ValueError("Full reader metadata was changed in packaging")
        if audit_device_types(archive) != metadata["device_types"]:
            raise ValueError("Unexpected reader device targets")
        app = json.loads(archive.read("module.json"))["app"]
        for packed, declared in (("bundleName", "bundle_name"), ("versionName", "hap_version_name"), ("versionCode", "version_code")):
            if app.get(packed) != metadata[declared]:
                raise ValueError(f"Unexpected actual full reader {packed}: {app.get(packed)!r} != {metadata[declared]!r}")
        if app.get("minAPIVersion") != 260000026 or app.get("targetAPIVersion") != 260000026:
            raise ValueError("Unexpected full reader API baseline")
        required = set(expected) | {"libflutter.so", "libapp.so"}
        actual = {Path(name).name for name in names if name.startswith("libs/arm64-v8a/") and name.endswith(".so")}
        if actual != required:
            raise ValueError(f"Unreviewed/missing reader libraries: {actual ^ required}")
        records = []
        for name in sorted(required):
            data = archive.read(f"libs/arm64-v8a/{name}")
            validate_elf(data)
            checksum = hashlib.sha256(data).hexdigest()
            if name in expected and checksum != expected[name]:
                raise ValueError(f"Rewritten reader native library: {name}")
            records.append({"name": name, "bytes": len(data), "sha256": checksum})
        for name, checksum in expected_assets.items():
            if hashlib.sha256(archive.read(ASSET_PREFIX + name)).hexdigest() != checksum:
                raise ValueError(f"Rewritten/missing real application asset: {name}")
        return {"bundle_name": app["bundleName"], "version_name": app["versionName"], "version_code": app["versionCode"],
                "minimum_api": app["minAPIVersion"], "target_api": app["targetAPIVersion"],
                "device_types": metadata["device_types"], "libraries": records, "asset_count": len(expected_assets)}


def check_real_source(metadata):
    for name, checksum in metadata["source_files"].items():
        if name.startswith("lib/") and digest(PROJECT / name) != checksum:
            raise ValueError(f"Prepared application Dart source differs: {name}")
    sources = {path.relative_to(PROJECT).as_posix() for path in (PROJECT / "lib").rglob("*.dart")}
    if sources != {name for name in metadata["source_files"] if name.startswith("lib/")}:
        raise ValueError("Missing or injected full application Dart source")
    if metadata["source_commit"] != os.environ["GITHUB_SHA"]:
        raise ValueError("Unexpected full reader source commit")
    registrant = PROJECT / "ohos/entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets"
    if "InAppWebViewFlutterPlugin" not in registrant.read_text(encoding="utf-8"):
        raise ValueError("Actual OHOS WebView plugin registration is missing")


def build(flutter_sdk):
    CI.mkdir(parents=True, exist_ok=True)
    report = {"status": "building", "purpose": "full_reader_experiment", "commit": os.environ.get("GITHUB_SHA"),
              "signed": False, "reader_integrated": True, "runtime_verified": False}
    try:
        run_logged([sys.executable, ROOT / "tool/harmonyos/prepare_full_app.py", "project", "--flutter-sdk", flutter_sdk], "full-app-prepare")
        metadata = json.loads((PROJECT / "assets/harmonyos-app-build.json").read_text(encoding="utf-8"))
        check_real_source(metadata)
        for path in (BASE / "native/native-build.json", BASE / "full-native/extra-native-build.json"):
            native = json.loads(path.read_text(encoding="utf-8"))
            if native["sdk_profile"] != "harmony-ci" or native["sdk_api"] != 26:
                raise ValueError("Cloud reader HAP requires fresh API 26 libraries")
        flutter = flutter_sdk / "bin/flutter"
        run_logged([flutter, "analyze", "--no-pub", "--fatal-infos"], "full-app-analyze", PROJECT)
        host = require_within(BASE / "full-host", BASE)
        host_sources = {"flutter_qjs": BASE / "deps/flutter_qjs", **{name: DEPS / name for name in ("zip_flutter", "flutter_7zip", "lodepng_flutter")}}
        run_logged(["cmake", "-S", ROOT / ".github/scripts/native_test_libraries", "-B", host, "-G", "Ninja",
                    "-DCMAKE_BUILD_TYPE=Release", *[f"-D{name.upper()}_ROOT={path}" for name, path in host_sources.items()]], "full-app-host-prepare")
        run_logged(["cmake", "--build", host, "--parallel", "2"], "full-app-host-build")
        previous_path = os.environ.get("LD_LIBRARY_PATH", "")
        os.environ["LD_LIBRARY_PATH"] = str(host / "lib") + (":" + previous_path if previous_path else "")
        try:
            run_logged([flutter, "test", "--no-pub", "--reporter", "expanded", *TESTS], "full-app-test", PROJECT)
        finally:
            if previous_path:
                os.environ["LD_LIBRARY_PATH"] = previous_path
            else:
                os.environ.pop("LD_LIBRARY_PATH", None)
        run_logged([flutter, "build", "hap", "--release", "--no-codesign", "--target-platform", "ohos-arm64", "--no-pub", "--target", "lib/main.dart",
                    "--build-name", FULL_CONFIG["hap_version_name"], "--build-number", str(FULL_CONFIG["version_code"])], "full-app-build", PROJECT)
        check_real_source(metadata)
        haps = list((PROJECT / "build/ohos/hap").glob("*-unsigned.hap"))
        if len(haps) != 1:
            raise ValueError("Expected one real reader unsigned HAP")
        expected_assets = {**metadata["bundled_assets"], "CHANGELOG.md": metadata["source_files"]["CHANGELOG.md"]}
        expected_assets["pubspec.yaml"] = digest(PROJECT / "pubspec.yaml")
        audit = audit_full_hap(haps[0], metadata, expected_assets)
        artifacts = CI / "full-app-artifacts"
        artifacts.mkdir(parents=True, exist_ok=True)
        exported = artifacts / f"venera-next-{FULL_CONFIG['version_name']}-arm64-unsigned.hap"
        shutil.copy2(haps[0], exported)
        if digest(exported) != digest(haps[0]):
            raise ValueError("Exported reader HAP differs from the audited bytes")
        report.update(status="packaging_pass", hap=exported.name, bytes=exported.stat().st_size,
                      sha256=digest(exported), packaged_app=audit, build=metadata, expected_assets=expected_assets)
        (artifacts / "full-app-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        (artifacts / "SHA256SUMS").write_text(f"{digest(exported)}  {exported.name}\n", encoding="utf-8")
        for language in ("zh", "en"):
            guide = ROOT / f"doc/distribution/harmonyos-reader.{language}.md"
            text = guide.read_text(encoding="utf-8")
            for companion in ("zh", "en"):
                text = text.replace(f"harmonyos-reader.{companion}.md", f"install.{companion}.md")
            (artifacts / f"install.{language}.md").write_text(text, encoding="utf-8")
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        (CI / "full-app-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Audited and exported {report['hap']}; no signing or device runtime is claimed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    args = parser.parse_args()
    build(args.flutter_sdk.resolve())


if __name__ == "__main__":
    main()
