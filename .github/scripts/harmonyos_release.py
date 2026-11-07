#!/usr/bin/env python3
"""Bind an unsigned HarmonyOS beta to its exact mainline or frozen source."""

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
NEXT_PIN = ".github/harmonyos-next.json"
NEXT_BUILD = 245
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-rc\.\d+)?")
ASSETS = "resources/rawfile/flutter_assets/"
METADATA = ASSETS + "assets/harmonyos-app-build.json"
BUNDLE = "com.github.cyrilpeng.veneranext.harmony"
NATIVE = {"librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so",
          "liblodepng_flutter.so", "libzip_flutter.so", "libflutter_7zip.so", "libinappwebview.so"}
NEXT_NATIVE = NATIVE - {"liblodepng_flutter.so", "libflutter_7zip.so"} | {"libvenera_native.so"}
NOTICE = "assets/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
NOTICE_SOURCE = "packages/venera_native/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
# Legacy schema 1/2 pins permit only release metadata after their baseline.
RELEASE_ONLY = {"release.json", "CHANGELOG.md", "README.md", "README.en.md", "alt_store.json", PIN, NEXT_PIN,
                ".github/scripts/harmonyos_release.py", ".github/scripts/tests/test_harmonyos_release.py"}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], timeout=120)


def blob(root, commit, name):
    return git(root, "show", f"{commit}:{name}")


def tracked(root, commit):
    return {name.decode("utf-8") for name in git(root, "ls-tree", "-r", "--name-only", "-z", commit).split(b"\0") if name}


def load_pin(root, *, next_candidate=False):
    value = json.loads((root / (NEXT_PIN if next_candidate else PIN)).read_text(encoding="utf-8"))
    unified = next_candidate and value.get("schema") == 3
    fields = ({"schema", "source_mode", "first_release_build"} if unified
              else {"schema", "source_commit", "main_baseline", "first_release_build"})
    if next_candidate:
        fields.add("release_enabled")
    if (set(value) != fields
            or type(value["schema"]) is not int
            or value["schema"] not in ((2, 3) if next_candidate else (1,))
            or (unified and value["source_mode"] != "release_commit")
            or (not unified and any(not isinstance(value[key], str) or not SHA.fullmatch(value[key])
                                    for key in ("source_commit", "main_baseline")))
            or type(value["first_release_build"]) is not int
            or value["first_release_build"] < (NEXT_BUILD if next_candidate else 244)
            or (next_candidate and type(value["release_enabled"]) is not bool)):
        raise ValueError("Invalid immutable HarmonyOS release pin")
    return value


def selected_source_commit(root, pin):
    if pin["schema"] == 3:
        return git(root, "rev-parse", "HEAD").decode().strip()
    return pin["source_commit"]


def select_pin(root, *, preview_next=False):
    config = json.loads((root / "release.json").read_text(encoding="utf-8"))
    build = config.get("build")
    if type(build) is not int:
        raise ValueError("Invalid caller release build")
    return load_pin(root, next_candidate=preview_next or build >= NEXT_BUILD)


def check_distribution(pin, *, tagged):
    if tagged and pin["schema"] >= 2 and not pin["release_enabled"]:
        raise ValueError("The reviewed next candidate is preview only; explicitly enable unsigned beta distribution after source, build and asset review")


def is_release_only(name):
    return name in RELEASE_ONLY or name.startswith(("doc/", ".github/workflows/"))


def normalized_pubspec(data):
    text = data.decode("utf-8-sig").replace("\r\n", "\n")
    return re.sub(r"^version: [^\n]+$", "version: <release>", text, flags=re.M)


def check_sources(root, source, pin):
    release_commit = git(root, "rev-parse", "HEAD").decode().strip()
    source_commit = git(source, "rev-parse", "HEAD").decode().strip()
    if source_commit != selected_source_commit(root, pin):
        raise ValueError("HarmonyOS checkout does not match the pinned commit")
    for checkout, head in ((root, release_commit), (source, source_commit)):
        if git(checkout, "diff", "--name-only", "HEAD", "--"):
            raise ValueError("Release source has uncommitted changes")
        if pin["schema"] != 3 and subprocess.run(
                ["git", "-C", str(checkout), "merge-base", "--is-ancestor", pin["main_baseline"], head],
                timeout=120).returncode != 0:
            raise ValueError("Both checkouts must contain the reviewed main baseline")
        if pin["schema"] == 3 and git(checkout, "ls-files", "--others", "--exclude-standard"):
            raise ValueError("Mainline release source contains untracked inputs")
    if git(source, "ls-files", "--others", "--exclude-standard"):
        raise ValueError("HarmonyOS source contains untracked inputs")
    if pin["schema"] == 3:
        return release_commit
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


def release_metadata(root, commit):
    config = json.loads(blob(root, commit, "release.json"))
    version, build = config.get("version"), config.get("build")
    if not isinstance(version, str) or not VERSION.fullmatch(version) or type(build) is not int or not 3 < build <= 2147483647:
        raise ValueError("Invalid release version or non-increasing legacy HAP build number")
    pubspec = blob(root, commit, "pubspec.yaml").decode("utf-8-sig")
    if re.findall(r"^version:[ \t]*([^\r\n]+)", pubspec, re.M) != [f"{version}+{build}"]:
        raise ValueError("Caller pubspec and release metadata differ")
    changelog = blob(root, commit, "CHANGELOG.md").decode("utf-8-sig").replace("\r\n", "\n")
    if not re.search(r"^## " + re.escape("v" + version) + r"\s*$", changelog, re.M):
        raise ValueError("Missing release changelog section")
    return version, build, changelog


def context(root, source, environ, *, preview_next=False):
    tagged = environ.get("GITHUB_REF_TYPE") == "tag"
    if preview_next and tagged:
        raise ValueError("A release tag cannot use the next-candidate preview")
    caller_commit = git(root, "rev-parse", "HEAD").decode().strip()
    caller_version, caller_build, changelog = release_metadata(root, caller_commit)
    next_candidate = preview_next or caller_build >= NEXT_BUILD
    pin = load_pin(root, next_candidate=next_candidate)
    source_commit = selected_source_commit(root, pin)
    release_commit = check_sources(root, source, pin)
    try:
        committed_pin = json.loads(blob(root, release_commit, NEXT_PIN if next_candidate else PIN))
    except subprocess.CalledProcessError as error:
        raise ValueError("The release pin must be part of the caller's committed inputs") from error
    if pin != committed_pin:
        raise ValueError("The release pin differs from the caller's committed inputs")
    version, build = caller_version, caller_build
    if preview_next:
        version, build, changelog = release_metadata(source, source_commit)
    if next_candidate and build < pin["first_release_build"]:
        raise ValueError("The next reader cannot rebuild the frozen 244 release")
    check_distribution(pin, tagged=tagged)
    if tagged and (environ.get("GITHUB_REF_NAME") != "v" + version or build < pin["first_release_build"]):
        raise ValueError("Release tag/version is mismatched or predates HAP distribution")
    if tagged and git(root, "rev-parse", f"refs/tags/v{version}^{{commit}}").decode().strip() != release_commit:
        raise ValueError("Release tag does not identify the checked-out commit")
    if environ.get("GITHUB_SHA", release_commit) != release_commit:
        raise ValueError("Checkout is not the caller's exact release commit")
    value = {"schema": pin["schema"], "channel": "harmonyos-beta", "source_commit": source_commit,
             "release_commit": release_commit,
            "version": version, "build": build, "tag": "v" + version,
            "run_id": environ.get("GITHUB_RUN_ID", "local"), "tagged": tagged,
            "changelog_sha256": sha256(changelog.encode()), "changelog": changelog}
    if pin["schema"] == 3:
        value["source_mode"] = "release_commit"
    else:
        value["main_baseline"] = pin["main_baseline"]
    if next_candidate:
        value.update(preview=preview_next, caller_version=caller_version, caller_build=caller_build)
    return value


def public_context(value):
    return {key: item for key, item in value.items() if key != "changelog"}


def asset_names(version):
    return {"hap": f"VeneraNext-{version}-harmonyos-arm64-unsigned.hap",
            "manifest": "harmonyos-manifest.json", "checksums": "harmonyos-SHA256SUMS",
            "zh": "harmonyos-install.zh.md", "en": "harmonyos-install.en.md"}


def elf(data):
    return (len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01"
            and struct.unpack_from("<HH", data, 16) == (3, 183))


def package_digest(source, commit, prefix, files):
    result = hashlib.sha256()
    for name in sorted(n for n in files if n.startswith(prefix + "/")):
        result.update(name[len(prefix) + 1:].encode("utf-8") + b"\0")
        result.update(blob(source, commit, name))
    return result.hexdigest()


def verify_next_dependencies(metadata, source, commit, files):
    config = json.loads(blob(source, commit, "tool/harmonyos/full_app_config.json"))
    inventory = json.loads(blob(source, commit, "doc/development/git_dependencies.json"))
    local = {item["dependency"]: item for item in inventory["local_packages"]}
    if set(local) != set(config["project_packages"]):
        raise ValueError("Next reader project package inventory differs")
    deps = metadata["dependencies"]
    if set(deps) != set(local) | {"flutter_qjs", "webview", "webview_api", "code_assets"} | set(config["hosted"]):
        raise ValueError("Incomplete next reader dependency inventory")
    for name, item in local.items():
        expected = {"project_path": item["path"], "version": item["version"],
                    "prepared_sha256": package_digest(source, commit, item["path"], files)}
        if deps[name] != expected:
            raise ValueError("Next reader project package differs: " + name)
    toolchain = json.loads(blob(source, commit, "tool/harmonyos/toolchain.json"))
    for name in ("flutter_qjs", "webview", "webview_api", "code_assets"):
        revision = toolchain["quickjs"]["revision"] if name == "flutter_qjs" else config[name]["revision"]
        if deps[name].get("revision") != revision:
            raise ValueError("Next reader Git dependency differs: " + name)
    for name, spec in config["hosted"].items():
        if any(deps[name].get(key) != spec[key] for key in ("version", "sha256")):
            raise ValueError("Next reader hosted dependency differs: " + name)
    for name, item in deps.items():
        if not re.fullmatch(r"[0-9a-f]{64}", item.get("prepared_sha256", "")):
            raise ValueError("Missing prepared dependency fingerprint: " + name)


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
    next_candidate = expected["schema"] >= 2
    native_names = NEXT_NATIVE if next_candidate else NATIVE
    source_names = tracked(source, commit)
    files = {n for n in source_names if n in {"pubspec.yaml", "pubspec.lock", "CHANGELOG.md"}
             or n.startswith("assets/") or (n.startswith("lib/") and n.endswith(".dart"))}
    if next_candidate:
        files |= {n for n in source_names if n == "release.json" or n.startswith("packages/")}
    if set(metadata["source_files"]) != files:
        raise ValueError("Incomplete real reader source inventory")
    for name, digest in metadata["source_files"].items():
        if sha256(blob(source, commit, name)) != digest:
            raise ValueError("Source fingerprint differs from the pinned Git blob: " + name)
    if next_candidate:
        verify_next_dependencies(metadata, source, commit, source_names)
    for language in ("zh", "en"):
        guide = blob(source, commit, f"doc/distribution/harmonyos-reader.{language}.md").decode("utf-8").replace("\r\n", "\n")
        for companion in ("zh", "en"):
            guide = guide.replace(f"harmonyos-reader.{companion}.md", f"harmonyos-install.{companion}.md")
        if (directory / names[language]).read_text(encoding="utf-8") != guide:
            raise ValueError("Installation guide differs from the reviewed source")
    native = metadata["native_libraries"]
    if set(native) != native_names:
        raise ValueError("Incomplete native library manifest")
    pubspec = blob(source, commit, "pubspec.yaml").decode("utf-8-sig")
    bundled = set(re.findall(r"^    - (assets/[^\r\n]+)$", pubspec, re.M))
    bundled_sources = {name: name for name in bundled}
    if next_candidate:
        bundled.add(NOTICE)
        bundled_sources[NOTICE] = NOTICE_SOURCE
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
        if libraries != {"libs/arm64-v8a/" + n for n in native_names | {"libapp.so", "libflutter.so"}}:
            raise ValueError("Missing/unreviewed/wrong-architecture native libraries")
        for name in libraries:
            data = archive.read(name)
            if not elf(data) or (Path(name).name in native and sha256(data) != native[Path(name).name]):
                raise ValueError("Invalid or rewritten native library: " + name)
        for name in bundled:
            digest = metadata["source_files"][bundled_sources[name]]
            if sha256(archive.read(ASSETS + name)) != digest or metadata["bundled_assets"][name] != digest:
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
    if expected.get("preview"):
        raise ValueError("Next-candidate preview assets cannot be published to a release")
    if expected.get("schema", 1) >= 2 and expected.get("tagged") is not True:
        raise ValueError("Next reader assets require a verified release-tag context before publication")
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


def read_remote_release(tag, *, published):
    if published:
        remote = json.loads(gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}"))
        if not isinstance(remote, dict):
            raise ValueError("Invalid published release response")
        return remote

    # GitHub's tag endpoint only returns published releases. Locate the exact
    # draft across all pages, then fetch its current asset inventory by ID.
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases?per_page=100"))
    if (not isinstance(pages, list) or any(not isinstance(page, list) for page in pages)
            or any(not isinstance(item, dict) for page in pages for item in page)):
        raise ValueError("Invalid release list response")
    matches = [item for page in pages for item in page if item.get("tag_name") == tag]
    if len(matches) != 1:
        raise ValueError("Expected exactly one release draft for tag: " + tag)
    identifier = matches[0].get("id")
    if type(identifier) is not int or identifier <= 0 or matches[0].get("draft") is not True:
        raise ValueError("Expected a draft with a valid release ID")
    remote = json.loads(gh("api", f"repos/{REPOSITORY}/releases/{identifier}"))
    if (not isinstance(remote, dict) or type(remote.get("id")) is not int
            or remote.get("id") != identifier or remote.get("tag_name") != tag
            or remote.get("draft") is not True):
        raise ValueError("Release draft identity changed during verification")
    return remote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("config", "prepare", "verify", "verify-draft", "verify-published"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--preview-next", action="store_true",
                        help="Verify the reviewed >=245 candidate without rebuilding or publishing 244")
    args = parser.parse_args()
    if args.action == "config":
        if args.preview_next and os.environ.get("GITHUB_REF_TYPE") == "tag":
            raise ValueError("A release tag cannot use the next-candidate preview")
        pin = select_pin(args.root, preview_next=args.preview_next)
        check_distribution(pin, tagged=os.environ.get("GITHUB_REF_TYPE") == "tag")
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"source_commit={selected_source_commit(args.root, pin)}\n")
        print(json.dumps(pin | {"source_commit": selected_source_commit(args.root, pin)}))
        return
    if args.source_root is None:
        parser.error("--source-root is required")
    expected = context(args.root, args.source_root, os.environ, preview_next=args.preview_next)
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
        published = args.action == "verify-published"
        release = read_remote_release(expected["tag"], published=published)
        check_remote_release(release, expected, assets, published=published)
    print("Verified HarmonyOS source, version, native libraries and all five release assets")


if __name__ == "__main__":
    main()
