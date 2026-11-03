#!/usr/bin/env python3
"""Bind an unsigned HarmonyOS beta to one reviewed source and one release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile


REPOSITORY = "CyrilPeng/Venera-Next"
PIN = ".github/harmonyos-release.json"
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-rc\.\d+)?")
ASSETS = "resources/rawfile/flutter_assets/"
METADATA = ASSETS + "assets/harmonyos-app-build.json"
BUNDLE = "com.github.cyrilpeng.veneranext.harmony"
NATIVE = {"librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so",
          "liblodepng_flutter.so", "libzip_flutter.so", "libflutter_7zip.so", "libinappwebview.so"}
# These files cannot change the reader built from the independent branch.
RELEASE_ONLY = {"release.json", "CHANGELOG.md", "README.md", "README.en.md", "alt_store.json", PIN,
                ".github/scripts/harmonyos_release.py", ".github/scripts/tests/test_harmonyos_release.py"}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], timeout=120)


def blob(root, commit, name):
    return git(root, "show", f"{commit}:{name}")


def tracked(root, commit):
    return {name.decode("utf-8") for name in git(root, "ls-tree", "-r", "--name-only", "-z", commit).split(b"\0") if name}


def load_pin(root):
    value = json.loads((root / PIN).read_text(encoding="utf-8"))
    if (set(value) != {"schema", "source_commit", "main_baseline", "first_release_build"}
            or type(value["schema"]) is not int or value["schema"] != 1
            or any(not isinstance(value[key], str) or not SHA.fullmatch(value[key])
                   for key in ("source_commit", "main_baseline"))
            or type(value["first_release_build"]) is not int or value["first_release_build"] < 244):
        raise ValueError("Invalid immutable HarmonyOS release pin")
    return value


def is_release_only(name):
    return name in RELEASE_ONLY or name.startswith(("doc/", ".github/workflows/"))


def normalized_pubspec(data):
    text = data.decode("utf-8-sig").replace("\r\n", "\n")
    return re.sub(r"^version: [^\n]+$", "version: <release>", text, flags=re.M)


def check_sources(root, source, pin):
    release_commit = git(root, "rev-parse", "HEAD").decode().strip()
    source_commit = git(source, "rev-parse", "HEAD").decode().strip()
    if source_commit != pin["source_commit"]:
        raise ValueError("HarmonyOS checkout does not match the pinned commit")
    for checkout, head in ((root, release_commit), (source, source_commit)):
        if git(checkout, "diff", "--name-only", "HEAD", "--"):
            raise ValueError("Release source has uncommitted changes")
        if subprocess.run(["git", "-C", str(checkout), "merge-base", "--is-ancestor",
                           pin["main_baseline"], head], timeout=120).returncode != 0:
            raise ValueError("Both checkouts must contain the reviewed main baseline")
    if git(source, "ls-files", "--others", "--exclude-standard"):
        raise ValueError("HarmonyOS source contains untracked inputs")
    changed = {p.decode("utf-8") for p in git(root, "diff", "--name-only", "-z",
                                             pin["main_baseline"], release_commit, "--").split(b"\0") if p}
    stale = []
    for name in sorted(changed):
        if is_release_only(name):
            continue
        if name == "pubspec.yaml" and normalized_pubspec(blob(root, pin["main_baseline"], name)) == normalized_pubspec(blob(root, release_commit, name)):
            continue
        stale.append(name)
    if stale:
        raise ValueError("Sync main into HarmonyOS, validate it, then update the pin; stale files: " + ", ".join(stale))
    return release_commit


def context(root, source, environ):
    pin = load_pin(root)
    release_commit = check_sources(root, source, pin)
    config = json.loads(blob(root, release_commit, "release.json"))
    version, build = config.get("version"), config.get("build")
    if not isinstance(version, str) or not VERSION.fullmatch(version) or type(build) is not int or not 3 < build <= 2147483647:
        raise ValueError("Invalid release version or non-increasing legacy HAP build number")
    pubspec = blob(root, release_commit, "pubspec.yaml").decode("utf-8-sig")
    if re.findall(r"^version:[ \t]*([^\r\n]+)", pubspec, re.M) != [f"{version}+{build}"]:
        raise ValueError("Caller pubspec and release metadata differ")
    changelog = blob(root, release_commit, "CHANGELOG.md").decode("utf-8-sig").replace("\r\n", "\n")
    if not re.search(r"^## " + re.escape("v" + version) + r"\s*$", changelog, re.M):
        raise ValueError("Missing release changelog section")
    tagged = environ.get("GITHUB_REF_TYPE") == "tag"
    if tagged and (environ.get("GITHUB_REF_NAME") != "v" + version or build < pin["first_release_build"]):
        raise ValueError("Release tag/version is mismatched or predates HAP distribution")
    if tagged and git(root, "rev-parse", f"refs/tags/v{version}^{{commit}}").decode().strip() != release_commit:
        raise ValueError("Release tag does not identify the checked-out commit")
    if environ.get("GITHUB_SHA", release_commit) != release_commit:
        raise ValueError("Checkout is not the caller's exact release commit")
    return {"schema": 1, "channel": "harmonyos-beta", "source_commit": pin["source_commit"],
            "main_baseline": pin["main_baseline"], "release_commit": release_commit,
            "version": version, "build": build, "tag": "v" + version,
            "run_id": environ.get("GITHUB_RUN_ID", "local"), "tagged": tagged,
            "changelog_sha256": sha256(changelog.encode()), "changelog": changelog}


def public_context(value):
    return {key: item for key, item in value.items() if key != "changelog"}


def asset_names(version):
    return {"hap": f"VeneraNext-{version}-harmonyos-arm64-unsigned.hap",
            "manifest": "harmonyos-manifest.json", "checksums": "harmonyos-SHA256SUMS",
            "zh": "harmonyos-install.zh.md", "en": "harmonyos-install.en.md"}


def elf(data):
    return (len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01"
            and struct.unpack_from("<HH", data, 16) == (3, 183))


def verify_bundle(directory, expected, source):
    names = asset_names(expected["version"])
    actual = {p.name for p in directory.iterdir()}
    if actual != set(names.values()) or any(not p.is_file() or p.is_symlink() for p in directory.iterdir()):
        raise ValueError("Missing or unexpected HarmonyOS release assets")
    report = json.loads((directory / names["manifest"]).read_text(encoding="utf-8"))
    metadata = report["build"]
    release = public_context(expected)
    hap = directory / names["hap"]
    if (report.get("status") != "packaging_pass" or report.get("signed") is not False
            or report.get("runtime_verified") is not False or report.get("reader_integrated") is not True
            or report.get("commit") != expected["source_commit"] or report.get("hap") != hap.name
            or report.get("bytes") != hap.stat().st_size or report.get("sha256") != sha256(hap.read_bytes())
            or metadata.get("release") != release or metadata.get("source_commit") != expected["source_commit"]
            or metadata.get("purpose") != "full_reader_experiment" or metadata.get("entrypoint") != "lib/main.dart"
            or metadata.get("signed") is not False or metadata.get("runtime_verified") is not False
            or metadata.get("reader_integrated") is not True):
        raise ValueError("HAP is not an audited build of this source/release/run")
    if (directory / names["checksums"]).read_text(encoding="utf-8") != f"{report['sha256']}  {hap.name}\n":
        raise ValueError("HAP checksum file differs")
    commit = expected["source_commit"]
    files = {n for n in tracked(source, commit) if n in {"pubspec.yaml", "pubspec.lock", "CHANGELOG.md"}
             or n.startswith("assets/") or (n.startswith("lib/") and n.endswith(".dart"))}
    if set(metadata["source_files"]) != files:
        raise ValueError("Incomplete real reader source inventory")
    for name, digest in metadata["source_files"].items():
        if sha256(blob(source, commit, name)) != digest:
            raise ValueError("Source fingerprint differs from the pinned Git blob: " + name)
    for language in ("zh", "en"):
        guide = blob(source, commit, f"doc/distribution/harmonyos-reader.{language}.md").decode("utf-8").replace("\r\n", "\n")
        for companion in ("zh", "en"):
            guide = guide.replace(f"harmonyos-reader.{companion}.md", f"harmonyos-install.{companion}.md")
        if (directory / names[language]).read_text(encoding="utf-8") != guide:
            raise ValueError("Installation guide differs from the reviewed source")
    native = metadata["native_libraries"]
    if set(native) != NATIVE:
        raise ValueError("Incomplete native library manifest")
    pubspec = blob(source, commit, "pubspec.yaml").decode("utf-8-sig")
    bundled = set(re.findall(r"^    - (assets/[^\r\n]+)$", pubspec, re.M))
    if set(metadata["bundled_assets"]) != bundled or set(report["expected_assets"]) != bundled | {"pubspec.yaml", "CHANGELOG.md"}:
        raise ValueError("Incomplete bundled asset inventory")
    with zipfile.ZipFile(hap) as archive:
        members = archive.namelist()
        if len(members) != len(set(members)) or archive.testzip() is not None:
            raise ValueError("Duplicated or corrupt HAP members")
        if any(n.startswith("/") or ".." in n.replace("\\", "/").split("/") for n in members):
            raise ValueError("Unsafe HAP member")
        if json.loads(archive.read(METADATA)) != metadata:
            raise ValueError("Embedded source manifest differs")
        module = json.loads(archive.read("module.json"))
        app = module["app"]
        native_version = expected["version"].split("-")[0]
        if (app.get("bundleName") != BUNDLE or metadata.get("bundle_name") != BUNDLE
                or app.get("versionCode") != expected["build"] or metadata.get("version_code") != expected["build"]
                or app.get("versionName") != native_version or metadata.get("hap_version_name") != native_version
                or metadata.get("version_name") != expected["version"]
                or app.get("minAPIVersion") != 260000026 or app.get("targetAPIVersion") != 260000026
                or sorted(module["module"].get("deviceTypes", [])) != ["phone", "tablet"]):
            raise ValueError("Actual HAP identity/version/API differs")
        libraries = {n for n in members if n.startswith("libs/") and n.endswith(".so")}
        if libraries != {"libs/arm64-v8a/" + n for n in NATIVE | {"libapp.so", "libflutter.so"}}:
            raise ValueError("Missing/unreviewed/wrong-architecture native libraries")
        for name in libraries:
            data = archive.read(name)
            if not elf(data) or (Path(name).name in native and sha256(data) != native[Path(name).name]):
                raise ValueError("Invalid or rewritten native library: " + name)
        for name in bundled:
            if sha256(archive.read(ASSETS + name)) != metadata["source_files"][name] or metadata["bundled_assets"][name] != metadata["source_files"][name]:
                raise ValueError("Bundled application asset differs: " + name)
        for name, digest in report["expected_assets"].items():
            if sha256(archive.read(ASSETS + name)) != digest:
                raise ValueError("Packaged asset checksum differs: " + name)
        if sha256(archive.read(ASSETS + "CHANGELOG.md")) != expected["changelog_sha256"]:
            raise ValueError("HAP does not contain the caller's release changelog")
        actual_version = re.findall(r"^version: ([^\r\n]+)", archive.read(ASSETS + "pubspec.yaml").decode(), re.M)
        if actual_version != [f"{expected['version']}+{expected['build']}"]:
            raise ValueError("Embedded Flutter version differs")
    return {p.name: {"bytes": p.stat().st_size, "sha256": sha256(p.read_bytes())} for p in directory.iterdir()}


def check_remote_release(release, expected, assets, *, published):
    if (release.get("tag_name") != expected["tag"] or release.get("draft") is not (not published)
            or release.get("prerelease") is not ("-" in expected["version"])):
        raise ValueError("Wrong release tag/state/channel")
    remote = release.get("assets", [])
    if not isinstance(remote, list) or any(not isinstance(item, dict) for item in remote):
        raise ValueError("Invalid remote release asset inventory")
    harmony_names = [item.get("name", "") for item in remote
                     if isinstance(item.get("name"), str)
                     and (item["name"].lower().endswith(".hap") or "harmonyos" in item["name"].lower())]
    if set(harmony_names) != set(assets) or len(harmony_names) != len(assets):
        raise ValueError("Unexpected or duplicated HarmonyOS release assets")
    for name, record in assets.items():
        matches = [item for item in remote if item.get("name") == name]
        if (len(matches) != 1 or matches[0].get("state") != "uploaded"
                or matches[0].get("size") != record["bytes"]
                or matches[0].get("digest") != "sha256:" + record["sha256"]):
            raise ValueError("Remote release asset missing/incomplete/different: " + name)


def gh(*args):
    return subprocess.check_output(["gh", *args], timeout=120).decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("config", "prepare", "verify", "verify-draft", "verify-published"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    if args.action == "config":
        pin = load_pin(args.root)
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"source_commit={pin['source_commit']}\n")
        print(json.dumps(pin))
        return
    if args.source_root is None:
        parser.error("--source-root is required")
    expected = context(args.root, args.source_root, os.environ)
    if args.action == "prepare":
        if args.output is None:
            parser.error("--output is required")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(public_context(expected)))
        return
    if args.artifacts is None:
        parser.error("--artifacts is required")
    assets = verify_bundle(args.artifacts, expected, args.source_root)
    if args.action in ("verify-draft", "verify-published"):
        release = json.loads(gh("api", f"repos/{REPOSITORY}/releases/tags/{expected['tag']}"))
        check_remote_release(release, expected, assets, published=args.action == "verify-published")
    print("Verified HarmonyOS source, version, native libraries and all five release assets")


if __name__ == "__main__":
    main()
