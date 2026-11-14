"""Compile Android primitives and run their existing JVM regressions on Linux."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

from test_suites import ROOT, load_manifest, matches, paths

KOTLIN_VERSION = "2.1.0"
COMPILER_SHA256 = "b6698d5728ad8f9edcdd01617d638073191d8a03139cc538a391b4e3759ad297"
PROFILES = {
    "android-jvm": (KOTLIN_VERSION, COMPILER_SHA256, "android/settings.gradle",
                    r'id "org.jetbrains.kotlin.android" version "([^"]+)"'),
    "share-android": ("2.2.0", "1adb6f1a5845ba0aa5a59e412e44c8e405236b957de1a9683619f1dca3b16932",
                      "packages/share_plus/android/build.gradle", r"ext.kotlin_version\s*=\s*'([^']+)'"),
}


def compiler(directory: Path, version: str = KOTLIN_VERSION, checksum: str = COMPILER_SHA256) -> Path:
    executable = directory / "kotlinc/bin/kotlinc"
    archive = directory / "compiler.zip"
    if archive.is_file():
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise ValueError(f"Cached Kotlin {version} compiler checksum mismatch")
        if executable.is_file():
            return executable
    directory.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/JetBrains/kotlin/releases/download/v{version}/kotlin-compiler-{version}.zip"
    with urllib.request.urlopen(url, timeout=30) as response, archive.open("wb") as target:
        while block := response.read(1024 * 1024):
            target.write(block)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != checksum:
        raise ValueError(f"Kotlin {version} compiler checksum mismatch: {digest}")
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            target = (directory / entry.filename).resolve()
            if not target.is_relative_to(directory.resolve()):
                raise ValueError(f"Compiler archive escapes its directory: {entry.filename}")
        bundle.extractall(directory)
    for path in (directory / "kotlinc/bin").iterdir():
        if path.is_file() and not path.suffix:
            path.chmod(0o755)
    return executable


def owned_groups(manifest: dict, root: Path = ROOT) -> list[dict]:
    all_paths = paths(root)
    owners = [owner for owner in manifest["external"] if owner.get("jvm_groups")]
    if {owner["id"] for owner in owners} != set(PROFILES):
        raise ValueError("Every JVM owner requires its declared compiler profile")
    seen = set()
    for owner in owners:
        version, _, source, pattern = PROFILES[owner["id"]]
        declared = re.search(pattern, (root / source).read_text(encoding="utf-8"))
        if declared is None or declared.group(1) != version:
            raise ValueError(f"Standalone Kotlin compiler must match {source}")
        tests = [group["test"] for group in owner["jvm_groups"]]
        discovered = [path for path in all_paths if path.endswith(".kt") and
                      any(matches(path, pattern) for pattern in owner["include"])]
        if len(set(tests)) != len(tests) or sorted(tests) != sorted(discovered) or seen.intersection(tests):
            raise ValueError(f"Unowned, duplicate or stale JVM test entrypoint: {owner['id']}")
        seen.update(tests)
        for group in owner["jvm_groups"]:
            if not group["sources"] or not group["main"]:
                raise ValueError("JVM regressions must compile their production primitives and run their main")
            for name in group["sources"]:
                if name not in all_paths or not name.endswith(".kt") or "/src/main/" not in name:
                    raise ValueError(f"Missing production JVM source: {name}")
    return owners


def run(command: list[str], log: Path) -> tuple[int, float]:
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", errors="replace")
        assert process.stdout is not None
        for line in process.stdout:
            output.write(line)
            print(line, end="", flush=True)
        process.stdout.close()
        return process.wait(), round(time.monotonic() - started, 3)


def java_version(text: str) -> int:
    match = re.search(r'(?:java|openjdk) version "(\d+)(?:[.\-\"]|$)', text)
    if match is None or int(match.group(1)) != 17:
        raise ValueError('JVM regressions require the actual Java 17 runtime')
    return int(match.group(1))


def compiler_version(text: str, expected: str) -> str:
    match = re.search(r'kotlinc-jvm (\S+) \(JRE (\d+)[.\-+)]', text)
    if match is None or match.group(1) != expected or int(match.group(2)) != 17:
        raise ValueError(f'Kotlin compiler must be {expected} and run with Java 17')
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, help="Optional application Kotlin 2.1 compiler")
    parser.add_argument("--output", type=Path, default=ROOT / "build/test-audit/android-jvm")
    args = parser.parse_args()
    if sys.platform != "linux":
        raise ValueError("Run the Android JVM regressions on Linux with Java 17")
    owners = owned_groups(load_manifest())
    args.output.mkdir(parents=True, exist_ok=True)
    all_sources = sorted({source for owner in owners for group in owner["jvm_groups"]
                          for source in [group["test"], *group["sources"]]})
    report = {"schema_version": 2, "profiles": [], "groups": []}
    try:
        java = shutil.which('java')
        if java is None:
            raise ValueError('Java 17 executable was not found')
        java_log = args.output / 'java-version.log'
        code, seconds = run([java, '-version'], java_log)
        if code:
            raise ValueError(f'Java version check failed: {code}')
        report['java'] = {'major': java_version(java_log.read_text(encoding='utf-8')),
                          'executable': java, 'wall_seconds': seconds}
    except Exception as error:
        report.update(success=False, preparation_error=str(error))
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(str(error), file=sys.stderr, flush=True)
        return 1
    result = 0
    for owner in owners:
        ident = owner["id"]
        version, checksum, version_source, _ = PROFILES[ident]
        groups = owner["jvm_groups"]
        sources = sorted({source for group in groups for source in [group["test"], *group["sources"]]})
        # The share package has its own Kotlin 2.2 declaration. Also compile
        # its primitives with the application's Kotlin 2.1 classpath, then run
        # the original share main independently with the package's compiler.
        compiled = all_sources if ident == "android-jvm" else sources
        profile = {"id": ident, "kotlin_version": version, "compiler_sha256": checksum,
                   "declared_version_source": version_source,
                   "sources": {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest()
                               for source in [version_source, *compiled]}, "groups": []}
        report["profiles"].append(profile)
        try:
            executable = args.compiler if ident == "android-jvm" and args.compiler else compiler(
                ROOT / "build/test-tools" / f"kotlin-{version}", version, checksum)
            version_log = args.output / f'compiler-version-{ident}.log'
            code, seconds = run([str(executable), '-version'], version_log)
            if code:
                raise ValueError(f'Kotlin {version} version check failed: {code}')
            profile['compiler_version_check'] = {
                'actual_version': compiler_version(version_log.read_text(encoding='utf-8'), version),
                'java_major': 17, 'wall_seconds': seconds}
            jar = args.output / f"{ident}.jar"
            code, duration = run([str(executable), "-jvm-target", "17", "-include-runtime", "-d", str(jar), *compiled],
                                 args.output / f"compile-{ident}.log")
            profile["compile"] = {"exit_code": code, "wall_seconds": duration}
            if code == 0:
                for group in groups:
                    code, seconds = run([java, "-ea", "-cp", str(jar), group["main"]],
                                        args.output / f"{Path(group['test']).stem}.log")
                    row = {"profile": ident, "kotlin_version": version, "test": group["test"], "main": group["main"],
                           "exit_code": code, "wall_seconds": seconds}
                    profile["groups"].append(row)
                    report["groups"].append(row)
                    if code != 0:
                        result = result or code
            else:
                result = result or code
            profile["success"] = profile["compile"]["exit_code"] == 0 and len(profile["groups"]) == len(groups) and all(
                row["exit_code"] == 0 for row in profile["groups"])
        except Exception as error:
            profile.update(success=False, preparation_error=str(error))
            print(f"{ident}: {error}", file=sys.stderr, flush=True)
            result = result or 1
    report["success"] = result == 0 and all(profile["success"] for profile in report["profiles"])
    (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
