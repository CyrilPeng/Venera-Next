"""Build and audit unsigned experimental HAPs, without signing or publishing."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from native_build import CONFIG, ROOT, digest, require_within, validate_elf
from prepare_probe import LIBRARIES, configure_profile, verify_native_report


BASE = ROOT / "build/harmonyos"
CI = BASE / "ci"


def run_logged(args, name, cwd=ROOT):
    logs = CI / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    print("RUN", " ".join(map(str, args)), flush=True)
    with (logs / f"{name}.txt").open("w", encoding="utf-8") as log:
        with subprocess.Popen(list(map(str, args)), cwd=cwd, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True,
                              encoding="utf-8", errors="replace") as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
            if process.wait():
                raise subprocess.CalledProcessError(process.returncode, args)


def audit_hap(hap, expected=None):
    if not hap.name.endswith("-unsigned.hap"):
        raise ValueError("Only an explicitly unsigned HAP may be exported")
    if expected is not None and set(expected) != set(LIBRARIES):
        raise ValueError("The probe requires a complete native hash manifest")
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or archive.testzip() is not None:
            raise ValueError("Duplicated or corrupt HAP members")
        required = {"libflutter.so", "libapp.so"} | (set(LIBRARIES) if expected else set())
        records = []
        for name in sorted(required):
            member = f"libs/arm64-v8a/{name}"
            if member not in names:
                raise ValueError(f"Missing ARM64 HAP library: {name}")
            data = archive.read(member)
            validate_elf(data)
            checksum = hashlib.sha256(data).hexdigest()
            if expected and name in expected and checksum != expected[name]:
                raise ValueError(f"Packaged native library differs from audited build: {name}")
            records.append({"name": member, "bytes": len(data), "sha256": checksum})
        return records


def build(stage, flutter_sdk, qjs_source=None):
    CI.mkdir(parents=True, exist_ok=True)
    flutter = flutter_sdk / "bin/flutter"
    project = require_within(BASE / ("blank" if stage == "blank" else "probe"), BASE)
    report = {"stage": stage, "status": "building", "commit": os.getenv("GITHUB_SHA"),
              "signed": False, "runtime_verified": False, "reader_integrated": False}
    try:
        expected = None
        if stage == "blank":
            if project.exists():
                raise ValueError("The CI blank app must be created in a fresh directory")
            run_logged([flutter, "create", "--platforms", "ohos", "--no-pub", "--org",
                        "com.github.cyrilpeng", "--project-name", "harmonyos_blank", project],
                       "blank-create")
            profile = project / "ohos/build-profile.json5"
            profile.write_text(configure_profile(profile.read_text(),
                               CONFIG["harmonyCiSdk"]["targetSdk"]), encoding="utf-8")
            run_logged([flutter, "pub", "get"], "blank-pub", project)
        else:
            if qjs_source is None:
                raise ValueError("The probe requires the pinned QuickJS source")
            run_logged([sys.executable, ROOT / "tool/harmonyos/prepare_probe.py",
                        "--flutter-sdk", flutter_sdk, "--qjs-source", qjs_source], "probe-prepare")
            native = verify_native_report(BASE / "native/native-build.json",
                                          BASE / "native/arm64-v8a")
            if native["sdk_profile"] != "harmony-ci":
                raise ValueError("The CI HAP must use the CI SDK native rebuild")
            expected = {library["name"]: library["sha256"] for library in native["libraries"]}
            run_logged([flutter, "analyze", "--no-pub"], "probe-analyze", project)
            run_logged([flutter, "test", "--no-pub", "--reporter", "expanded"], "probe-test", project)
        run_logged([flutter, "build", "hap", "--release", "--no-codesign",
                    "--target-platform", "ohos-arm64", "--no-pub"], f"{stage}-build", project)
        haps = sorted((project / "build/ohos/hap").glob("*-unsigned.hap"))
        if len(haps) != 1:
            raise ValueError("Expected exactly one unsigned HAP from a successful Flutter build")
        libraries = audit_hap(haps[0], expected)
        artifacts = CI / "artifacts"
        artifacts.mkdir(exist_ok=True)
        exported = artifacts / f"harmonyos-{stage}-arm64-unsigned.hap"
        shutil.copy2(haps[0], exported)
        report.update(status="packaging_pass", hap=exported.name,
                      bytes=exported.stat().st_size, sha256=digest(exported), libraries=libraries)
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        (CI / f"{stage}-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("blank", "probe"))
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--qjs-source", type=Path)
    args = parser.parse_args()
    build(args.stage, args.flutter_sdk.resolve(), args.qjs_source)


if __name__ == "__main__":
    main()
