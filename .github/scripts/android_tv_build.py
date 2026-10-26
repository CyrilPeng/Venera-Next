#!/usr/bin/env python3
"""Validate the experimental build identity and inspect actual signed APKs."""

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


def build_metadata(flavor, pubspec, environ):
    if flavor not in ("mobile", "tv"):
        raise ValueError("Android flavor must be mobile or tv")
    match = re.search(r"^version:\s*(\S+)\+(\d+)\s*$", pubspec, re.MULTILINE)
    if not match:
        raise ValueError("pubspec must contain an explicit base version and build")
    version, base_build = match.groups()
    revision = environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("GITHUB_SHA must be a full commit hash")
    number = int(base_build)
    label = "mobile"
    if flavor == "tv":
        if (
            environ.get("GITHUB_REF") != "refs/heads/android-tv"
            or environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
        ):
            raise ValueError("TV builds require a manual dispatch on android-tv")
        values = [environ.get(name, "") for name in ("GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT")]
        if not all(re.fullmatch(r"[1-9][0-9]*", value) for value in values):
            raise ValueError("TV builds require positive run and attempt numbers")
        run, attempt = map(int, values)
        number = 100000 + run
        label = f"alpha.{run}.{attempt}"
    if number <= 0 or number * 10 + 3 > 2100000000:
        raise ValueError("Android version code is out of range")
    return {
        "schema_version": 1,
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
        if application.get(ANDROID + "label") != "VeneraNext TV Alpha":
            raise ValueError("TV launcher identity is missing")
        if main.get(ANDROID + "screenOrientation") != "landscape":
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


def write_outputs(path, values):
    if path:
        with Path(path).open("a", encoding="utf-8") as stream:
            for name, value in values.items():
                stream.write(f"{name}={value}\n")


def verify_apks(metadata, sdk, github_output=None):
    flavor = metadata["flavor"]
    directory = Path(f"build/app/outputs/apk/{flavor}/release")
    platform = "android-tv" if flavor == "tv" else "android"
    expected = {
        abi: directory / f"VeneraNext-{metadata['base_version']}-{platform}{'' if abi == 'universal' else '-' + abi}.apk"
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
        fingerprints = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", certificate)
        if not fingerprints:
            raise ValueError(f"Missing verified signer certificate for {apk}")
        records.append((abi, apk, sorted(set(value.lower() for value in fingerprints))))
    if len({tuple(item[2]) for item in records}) != 1:
        raise ValueError("APK variants have different signing certificates")

    # Publish files only after every variant has passed the checks above.
    artifact_directory = Path("build/android-tv/artifacts")
    if flavor == "tv":
        artifact_directory.mkdir(parents=True, exist_ok=True)
    catalog = dict(metadata, apks=[])
    outputs = {}
    for abi, apk, fingerprints in records:
        target = apk
        if flavor == "tv":
            target = artifact_directory / f"VeneraNext-TV-{metadata['base_version']}-{metadata['build_label']}-{metadata['short_revision']}-{abi}.apk"
            shutil.copyfile(apk, target)
        digest = hashlib.sha256()
        with target.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        catalog["apks"].append({
            "abi": abi,
            "file": target.name,
            "version_code": metadata["build_number"] * 10 + ABI_CODES[abi],
            "sha256": digest.hexdigest(),
            "signer_sha256": fingerprints,
            "bytes": target.stat().st_size,
        })
        outputs["apk_" + abi.replace("-", "_")] = target.as_posix()
    catalog_path = artifact_directory / "build-manifest.json" if flavor == "tv" else Path("build/android-mobile-manifest.json")
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    outputs["manifest"] = catalog_path.as_posix()
    write_outputs(github_output, outputs)
    print(json.dumps(catalog, indent=2))


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
        else:
            verify_apks(json.loads(arguments.metadata.read_text(encoding="utf-8")), arguments.sdk, arguments.github_output)
    except (ValueError, ET.ParseError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Android artifact validation failed: {error}\n")


if __name__ == "__main__":
    main()
