#!/usr/bin/env python3
"""Validate both Android flavors, signed APKs and the complete release bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile


PACKAGE = "com.github.cyrilpeng.veneranext"
ANDROID = "{http://schemas.android.com/apk/res/android}"
ABI_CODES = {"armeabi-v7a": 1, "arm64-v8a": 2, "x86_64": 3, "universal": 0}
# Also enforced in Gradle so local builds use the same upgrade-safe sequence.
TV_BUILD_OFFSET = 200000
SIGNER_SHA256 = "3d990535d15d2ecb8f65f599db7725e1d83e10a5e801ddcdae262cc78983dc10"


def build_metadata(flavor, pubspec, environ):
    if flavor not in ("mobile", "tv"):
        raise ValueError("Android flavor must be mobile or tv")
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+(?:-rc\.\d+)?)\+(\d+)\s*$", pubspec, re.MULTILINE)
    if not match:
        raise ValueError("pubspec must contain an explicit base version and build")
    version, base_build = match.groups()
    revision = environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("GITHUB_SHA must be a full commit hash")
    number = int(base_build)
    if number <= 0:
        raise ValueError("Base build number must be positive")
    label = f"build.{number}"
    if flavor == "tv":
        number += TV_BUILD_OFFSET
    if number * 10 + 4 > 2100000000:
        raise ValueError("Android version code is out of range")
    return {
        "schema_version": 2,
        "flavor": flavor,
        "base_version": version,
        "base_build_number": int(base_build),
        "build_number": number,
        "build_label": label,
        "package": PACKAGE + (".tv" if flavor == "tv" else ""),
        "revision": revision,
        "short_revision": revision[:12],
        "ref": environ.get("GITHUB_REF"),
        "event": environ.get("GITHUB_EVENT_NAME"),
    }


def validate_manifest(xml, metadata, abi):
    manifest = ET.fromstring(xml)
    if manifest.get("package") != metadata["package"]:
        raise ValueError("Unexpected APK package")
    if manifest.get(ANDROID + "versionName") != metadata["base_version"]:
        raise ValueError("Unexpected APK base version")
    expected_code = metadata["build_number"] * 10 + ABI_CODES[abi]
    if manifest.get(ANDROID + "versionCode") != str(expected_code):
        raise ValueError(f"Unexpected APK versionCode; expected {expected_code}")
    application = manifest.find("application")
    if application is None or application.get(ANDROID + "debuggable", "false") != "false":
        raise ValueError("Expected a non-debuggable release application")
    activities = application.findall("activity")
    main = next(
        (item for item in activities if item.get(ANDROID + "name") == PACKAGE + ".MainActivity"),
        None,
    )
    if main is None or main.get(ANDROID + "exported") != "true":
        raise ValueError("MainActivity must use the original namespace and be exported")
    leanback = "android.intent.category.LEANBACK_LAUNCHER"
    tv_entries = [
        (activity, intent)
        for activity in activities
        for intent in activity.findall("intent-filter")
        if any(item.get(ANDROID + "name") == leanback for item in intent.findall("category"))
    ]
    features = {
        item.get(ANDROID + "name"): item.get(ANDROID + "required", "true")
        for item in manifest.findall("uses-feature")
    }
    if metadata["flavor"] == "tv":
        if len(tv_entries) != 1 or tv_entries[0][0] is not main:
            raise ValueError("Expected exactly one TV launcher on MainActivity")
        if not any(
            item.get(ANDROID + "name") == "android.intent.action.MAIN"
            for item in tv_entries[0][1].findall("action")
        ):
            raise ValueError("TV launcher must declare the MAIN action")
        if features.get("android.hardware.touchscreen") != "false":
            raise ValueError("TV must not require a touchscreen")
        if features.get("android.software.leanback") != "false":
            raise ValueError("TV must also allow generic Android boxes")
        if not application.get(ANDROID + "banner"):
            raise ValueError("TV banner is missing")
        if application.get(ANDROID + "label") != "VeneraNext TV":
            raise ValueError("TV launcher identity is missing")
        # apkanalyzer decodes the compiled orientation enum as integer 0.
        if main.get(ANDROID + "screenOrientation") not in ("landscape", "0", "0x0"):
            raise ValueError("TV must remain in landscape orientation")
    elif tv_entries or application.get(ANDROID + "banner"):
        raise ValueError("Mobile APK contains TV-only manifest entries")


def validate_contents(apk, metadata, abi):
    with zipfile.ZipFile(apk) as archive:
        pubspec = archive.read("assets/flutter_assets/pubspec.yaml").decode("utf-8-sig")
        expected = f"{metadata['base_version']}+{metadata['base_build_number']}"
        version = re.search(r"^version:\s*(\S+)\s*$", pubspec, re.MULTILINE)
        if not version or version.group(1) != expected:
            raise ValueError("Bundled source compatibility version was changed")
        native_abis = {
            name.split("/")[1]
            for name in archive.namelist()
            if re.fullmatch(r"lib/[^/]+/libapp\.so", name)
        }
        expected_abis = set(ABI_CODES) - {"universal"} if abi == "universal" else {abi}
        if native_abis != expected_abis:
            raise ValueError(f"Unexpected native ABI set: {sorted(native_abis)}")


def find_tool(name, sdk):
    executable = name + (".bat" if os.name == "nt" else "")
    if path := shutil.which(executable):
        return path
    pattern = f"cmdline-tools/*/bin/{executable}" if name == "apkanalyzer" else f"build-tools/*/{executable}"
    candidates = list(sdk.glob(pattern))
    if not candidates:
        raise ValueError(f"Cannot find {name} in Android SDK {sdk}")
    def version_key(path):
        # Prefer the stable latest alias, then numeric versions instead of lexical order.
        return ("latest" in path.parts, tuple(map(int, re.findall(r"\d+", str(path.parent)))))
    return str(max(candidates, key=version_key).resolve())


def run_tool(*command):
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout


def signer_fingerprints(output):
    fingerprints = re.findall(
        r"^(?:Signer #\d+|V[1-4](?:\.\d+)? Signer(?: #\d+)?):? certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$",
        output,
        re.MULTILINE,
    )
    if not fingerprints:
        raise ValueError("Missing verified signer certificate")
    return sorted(set(value.lower() for value in fingerprints))


def write_outputs(path, values):
    if path:
        with Path(path).open("a", encoding="utf-8") as stream:
            for name, value in values.items():
                stream.write(f"{name}={value}\n")


def apk_filename(metadata, abi):
    platform = "android-tv" if metadata["flavor"] == "tv" else "android"
    suffix = "" if abi == "universal" else "-" + abi
    return f"VeneraNext-{metadata['base_version']}-{platform}{suffix}.apk"


def apk_record(apk, metadata, abi, fingerprints):
    digest = hashlib.sha256()
    with apk.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "abi": abi,
        "file": apk.name,
        "version_code": metadata["build_number"] * 10 + ABI_CODES[abi],
        "sha256": digest.hexdigest(),
        "signer_sha256": fingerprints,
        "bytes": apk.stat().st_size,
    }


def verify_apks(metadata, sdk, github_output=None):
    flavor = metadata["flavor"]
    directory = Path(f"build/app/outputs/apk/{flavor}/release")
    expected = {
        abi: directory / apk_filename(metadata, abi)
        for abi in ABI_CODES
    }
    if set(directory.glob("*.apk")) != set(expected.values()):
        raise ValueError(f"Expected exactly four APK variants in {directory}")
    analyzer = find_tool("apkanalyzer", sdk)
    signer = find_tool("apksigner", sdk)
    records = []
    for abi, apk in expected.items():
        validate_manifest(run_tool(analyzer, "manifest", "print", str(apk)), metadata, abi)
        validate_contents(apk, metadata, abi)
        certificate = run_tool(signer, "verify", "--verbose", "--print-certs", str(apk))
        fingerprints = signer_fingerprints(certificate)
        if fingerprints != [SIGNER_SHA256]:
            raise ValueError("APK signing certificate differs from published mobile/TV builds")
        records.append((abi, apk, fingerprints))

    # Expose outputs only after every variant has passed the checks above.
    catalog = dict(metadata, apks=[])
    outputs = {}
    for abi, apk, fingerprints in records:
        catalog["apks"].append(apk_record(apk, metadata, abi, fingerprints))
        outputs["apk_" + abi.replace("-", "_")] = apk.as_posix()
    catalog_path = Path(f"build/android-{flavor}-manifest.json")
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    outputs["manifest"] = catalog_path.as_posix()
    write_outputs(github_output, outputs)
    print(json.dumps(catalog, indent=2))


def verify_release(directory, pubspec, environ):
    expected = set()
    for flavor in ("mobile", "tv"):
        metadata = build_metadata(flavor, pubspec, environ)
        catalog_path = directory / f"android-{flavor}-manifest.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        if not isinstance(catalog, dict):
            raise ValueError(f"Invalid Android catalog in {catalog_path}")
        records = catalog.pop("apks", None)
        if catalog != metadata:
            raise ValueError(f"Release provenance mismatch in {catalog_path}")
        if not isinstance(records, list) or len(records) != len(ABI_CODES):
            raise ValueError(f"Incomplete APK catalog in {catalog_path}")
        if any(not isinstance(record, dict) for record in records):
            raise ValueError(f"Invalid APK records in {catalog_path}")
        if {record.get("abi") for record in records} != set(ABI_CODES):
            raise ValueError(f"Missing or duplicate ABI in {catalog_path}")
        for record in records:
            abi = record["abi"]
            apk = directory / apk_filename(metadata, abi)
            expected.add(apk)
            if record != apk_record(apk, metadata, abi, [SIGNER_SHA256]):
                raise ValueError(f"Release APK does not match verified catalog: {apk}")
    if set(directory.glob("*.apk")) != expected:
        raise ValueError("Release must contain exactly four mobile and four TV APKs")
    print("Verified all eight mobile/TV APKs, release provenance and signing continuity")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata_command = commands.add_parser("metadata")
    metadata_command.add_argument("--flavor", required=True, choices=("mobile", "tv"))
    metadata_command.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    metadata_command.add_argument("--output", type=Path, default=Path("build/android-profile.json"))
    metadata_command.add_argument("--github-output")
    verify_command = commands.add_parser("verify")
    verify_command.add_argument("--metadata", type=Path, default=Path("build/android-profile.json"))
    verify_command.add_argument("--sdk", type=Path, default=Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", ""))))
    verify_command.add_argument("--github-output")
    release_command = commands.add_parser("verify-release")
    release_command.add_argument("--directory", type=Path, default=Path("outputs"))
    release_command.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    arguments = parser.parse_args()
    try:
        if arguments.command == "metadata":
            metadata = build_metadata(arguments.flavor, arguments.pubspec.read_text(encoding="utf-8-sig"), os.environ)
            arguments.output.parent.mkdir(parents=True, exist_ok=True)
            arguments.output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
            write_outputs(arguments.github_output, {
                "flavor": metadata["flavor"],
                "build_number": metadata["build_number"],
                "build_label": metadata["build_label"],
                "revision": metadata["short_revision"],
            })
            print(json.dumps(metadata, indent=2))
        elif arguments.command == "verify":
            verify_apks(json.loads(arguments.metadata.read_text(encoding="utf-8")), arguments.sdk, arguments.github_output)
        else:
            verify_release(arguments.directory, arguments.pubspec.read_text(encoding="utf-8-sig"), os.environ)
    except (ValueError, ET.ParseError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Android artifact validation failed: {error}\n")


if __name__ == "__main__":
    main()
