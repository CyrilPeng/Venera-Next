"""Prepare an isolated OHOS probe without changing the app or the Pub cache."""

import argparse
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

from ci_sdk import check_report_sdk
from native_build import (CONFIG, ROOT, build_fingerprint, check_qjs_source, digest,
                          require_within, source_fingerprint, validate_elf)
from sideload import DEVICE_TYPES, STAGES, build_metadata


BASE = ROOT / "build/harmonyos"
PROBE = BASE / "probe"
LIBRARIES = ("librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so")
QJS_ORIGINAL = "if (Platform.isAndroid) {\n    return DynamicLibrary.open('libqjs.so');"
QJS_OHOS = ("if (Platform.isAndroid || Platform.operatingSystem == 'ohos') {\n"
            "    return DynamicLibrary.open('libqjs.so');")


def patch_qjs_loader(text):
    if text.count(QJS_ORIGINAL) != 1:
        raise ValueError("Pinned QuickJS loader changed; review the patch instead of guessing")
    return text.replace(QJS_ORIGINAL, QJS_OHOS)


def configure_profile(text, target_sdk):
    # Replace only upstream template defaults; preserve local SDK/signing choices.
    for key, default in (("targetSdkVersion", "26.0.0"),
                         ("compatibleSdkVersion", "5.0.5(17)")):
        text = text.replace(f'"{key}": "{default}"',
                            f'"{key}": ' + json.dumps(target_sdk))
    return text


def configure_device_types(text):
    pattern = r'("deviceTypes"\s*:\s*)(\[[^\]]*\])'
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise ValueError("Expected one reviewed module deviceTypes declaration")
    declared = json.loads(matches[0].group(2))
    if declared not in (["phone"], list(DEVICE_TYPES)):
        raise ValueError("Unexpected template targets; review instead of broadening them silently")
    return re.sub(pattern, lambda match: match.group(1) + json.dumps(list(DEVICE_TYPES)), text)


def verify_native_report(report_path, library_dir):
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("status") != "cross_compile_pass":
        raise ValueError("A complete successful native build is required")
    if report.get("rhttp_source_sha256") != source_fingerprint():
        raise ValueError("rhttp sources changed; rebuild native libraries first")
    if report.get("build_fingerprint") != build_fingerprint():
        raise ValueError("Native build script/baseline changed; rebuild libraries first")
    check_report_sdk(report, CONFIG)
    for key, value in (("target", CONFIG["rust"]["target"]),
                       ("quickjs_revision", CONFIG["quickjs"]["revision"]),
                       ("sqlite_source_sha256", CONFIG["sqlite"]["amalgamationSha256"])):
        if report.get(key) != value:
            raise ValueError(f"Native baseline mismatch: {key}")
    records = {item["name"]: item for item in report["libraries"]}
    if len(report["libraries"]) != len(LIBRARIES) or set(records) != set(LIBRARIES):
        raise ValueError("Incomplete or duplicated native library manifest")
    for name in LIBRARIES:
        path = library_dir / name
        validate_elf(path.read_bytes())
        if digest(path) != records[name]["sha256"]:
            raise ValueError(f"Native artifact changed: {name}")
    return report


def command(args, cwd=ROOT, env=None):
    print("RUN", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def export_qjs(source, destination):
    check_qjs_source(source)
    destination = require_within(destination, BASE)
    destination.mkdir(parents=True, exist_ok=True)
    archive = BASE / "quickjs-pinned.tar"
    command(["git", "-C", source, "archive", "--format=tar", f"--output={archive}",
             CONFIG["quickjs"]["revision"]])
    with tarfile.open(archive) as package:
        for item in package.getmembers():
            require_within(destination / item.name, destination)
            if not (item.isfile() or item.isdir()):
                raise ValueError("Unexpected link or special file in QuickJS source")
        package.extractall(destination, filter="data")
    loader = destination / "lib/src/ffi.dart"
    loader.write_text(patch_qjs_loader(loader.read_text(encoding="utf-8")), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--qjs-source", type=Path, required=True)
    parser.add_argument("--native-dir", type=Path, default=BASE / "native",
                        help="Audited report/native library directory; defaults to the local build")
    parser.add_argument("--sideload-stage", choices=STAGES, default="baseline")
    parser.add_argument("--target-sdk", default=CONFIG["harmonyCiSdk"]["targetSdk"],
                        help="HarmonyOS SDK installed in DevEco, not the public native SDK")
    parser.add_argument("--dart-only", action="store_true",
                        help="Resolve Dart dependencies only, without OHOS plugin generation")
    parser.add_argument("--offline", action="store_true", help="Resolve only cached Pub dependencies")
    args = parser.parse_args()
    sdk = args.flutter_sdk.resolve()
    head = subprocess.check_output(["git", "-C", sdk, "rev-parse", "HEAD"], text=True).strip()
    if head != CONFIG["flutter"]["revision"]:
        raise ValueError("Flutter OH SDK does not match toolchain.json")
    libraries = args.native_dir / "arm64-v8a"
    report = verify_native_report(args.native_dir / "native-build.json", libraries)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    metadata = build_metadata(args.sideload_stage, commit, report)
    probe = require_within(PROBE, BASE)
    flutter = sdk / ("bin/flutter.bat" if os.name == "nt" else "bin/flutter")
    if not (probe / ".metadata").exists():
        if probe.exists() and any(probe.iterdir()):
            raise ValueError("Refusing to overwrite an unknown probe directory")
        command([flutter, "create", "--platforms", "ohos", "--no-pub", "--org",
                 "com.github.cyrilpeng", "--project-name", "harmonyos_probe", probe])
    export_qjs(args.qjs_source.resolve(), BASE / "deps/flutter_qjs")
    templates = Path(__file__).with_name("probe")
    for template in templates.rglob("*.template"):
        relative = template.relative_to(templates).with_suffix("")
        destination = require_within(probe / relative, probe)
        destination.parent.mkdir(parents=True, exist_ok=True)
        text = template.read_text(encoding="utf-8").replace(
            "{{RHTTP_PATH}}", os.path.relpath(ROOT / "packages/rhttp", probe).replace("\\", "/"))
        text = text.replace("{{PROBE_VERSION}}",
                            f"{metadata['version_name']}+{metadata['version_code']}")
        destination.write_text(text, encoding="utf-8")
    profile = probe / "ohos/build-profile.json5"
    text = profile.read_text(encoding="utf-8")
    profile.write_text(configure_profile(text, args.target_sdk), encoding="utf-8")
    module = probe / "ohos/entry/src/main/module.json5"
    module.write_text(configure_device_types(module.read_text(encoding="utf-8")), encoding="utf-8")
    native_dest = probe / "ohos/entry/libs/arm64-v8a"
    native_dest.mkdir(parents=True, exist_ok=True)
    for name in LIBRARIES:
        shutil.copy2(libraries / name, native_dest / name)
    assets = probe / "assets"
    assets.mkdir(exist_ok=True)
    # No account, signing material, device identifier or machine path is exported.
    (assets / "native-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (assets / "sideload-build.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    pub_args = ["pub", "get", "--enforce-lockfile"] + (["--offline"] if args.offline else [])
    if args.dart_only:
        env = os.environ.copy()
        env["FLUTTER_ROOT"] = str(sdk)
        dart = sdk / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt"
                      else "bin/cache/dart-sdk/bin/dart")
        command([dart, *pub_args], cwd=probe, env=env)
        print("Dart-only mode: OHOS plugin registration and HAP build are NOT verified.")
    else:
        command([flutter, *pub_args], cwd=probe)
    print(f"Prepared {probe}; this does not claim a HAP build or device verification.")


if __name__ == "__main__":
    main()
