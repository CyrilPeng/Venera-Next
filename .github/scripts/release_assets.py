#!/usr/bin/env python3
"""Check real release packages and bind their receipts to the compiler's source."""

import argparse
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tarfile
import tempfile
import zipfile

import android_tv_build as android
from build_linux_packages import versions


SCHEMA = 1
PLATFORMS = ("android_mobile", "android_tv", "windows", "macos", "ios", "linux_x64", "linux_arm64")
NOTICE = "assets/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
NOTICE_SOURCE = "packages/venera_native/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
FONT_ASSET = "assets/HarmonyOS%20Sans/HarmonyOS_Sans_SC/HarmonyOS_Sans_SC_Regular.ttf"
FONT_PATCH = ("  fonts:\n  - family: HarmonyOS Sans\n    fonts:\n"
              "      - asset: assets/HarmonyOS Sans/HarmonyOS_Sans_SC/HarmonyOS_Sans_SC_Regular.ttf\n")


def committed_policy(root, commit):
    path = ".github/release-policy.json"
    names = subprocess.check_output(["git", "-C", str(root), "ls-tree", "--name-only", commit, "--", path], timeout=30).decode().splitlines()
    if not names:
        return None
    policy = json.loads(git_blob(root, commit, path))
    require(type(policy.get("schema")) is int and policy["schema"] == 1
            and isinstance(policy.get("required_jobs"), list) and policy["required_jobs"]
            and all(isinstance(name, str) and name for name in policy["required_jobs"])
            and policy.get("verification_artifact") == "release-verification"
            and type(policy.get("security_max_age_hours")) is int and 0 < policy["security_max_age_hours"] <= 24,
            "Invalid original release gate policy")
    return policy


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git_blob(root, commit, name):
    return subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{name}"], timeout=30)


def source_context(root, environ):
    commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], timeout=30).decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", commit) and environ.get("GITHUB_SHA", commit) == commit,
            "Package checkout differs from the caller's exact commit")
    config = json.loads(git_blob(root, commit, "release.json"))
    version, build = config.get("version"), config.get("build")
    require(isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:-rc\.\d+)?", version)
            and type(build) is int and build > 0, "Invalid committed release metadata")
    pubspec = git_blob(root, commit, "pubspec.yaml").decode("utf-8-sig")
    require(re.findall(r"^version:[ \t]*([^\r\n]+)", pubspec, re.M) == [f"{version}+{build}"],
            "Committed pubspec and release version differ")
    return {"schema": SCHEMA, "source_commit": commit, "version": version, "build": build,
            "run_id": str(environ.get("GITHUB_RUN_ID", "local"))}


def expected_files(context):
    version, build = context["version"], context["build"]
    deb_version, _ = versions(f"{version}+{build}")
    result = {}
    for flavor in ("mobile", "tv"):
        metadata = android.build_metadata(flavor, f"version: {version}+{build}\n",
                                          {"GITHUB_SHA": context["source_commit"]})
        result["android_" + flavor] = {android.apk_filename(metadata, abi) for abi in android.ABI_CODES}
        result["android_" + flavor].add(f"android-{flavor}-manifest.json")
    result.update({
        "windows": {f"VeneraNext-{version}-windows.zip", f"VeneraNext-{version}-windows-installer.exe"},
        "macos": {f"VeneraNext-{version}+{build}.dmg"},
        "ios": {f"VeneraNext-ios-{version}+{build}.ipa"},
        "linux_x64": {f"venera-next_{deb_version}_amd64.deb", f"venera-next-{deb_version}-{build}.x86_64.rpm",
                      f"VeneraNext-{version}+{build}-x86_64.AppImage", f"venera-next-{version.replace('-', '_')}-{build}-x86_64.pkg.tar.zst"},
        "linux_arm64": {f"venera-next_{deb_version}_arm64.deb", f"venera-next-{deb_version}-{build}.aarch64.rpm",
                        f"VeneraNext-{version}+{build}-aarch64.AppImage"},
    })
    return result


def file_records(files):
    records = {}
    for path in files:
        require(path.is_file() and not path.is_symlink() and path.name not in records and path.stat().st_size > 0,
                "Missing, duplicate, linked or empty release file: " + path.name)
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        records[path.name] = {"bytes": path.stat().st_size, "sha256": digest}
    require(records, "No release files supplied")
    return records


def github_file_records(files):
    records = {}
    for name, record in files.items():
        remote_name = name.replace("~", ".")
        require(remote_name not in records, "Release filenames collide after GitHub normalization: " + remote_name)
        records[remote_name] = record
    return records


def check_remote_files(remote, files, *, optional=(), partial=False):
    expected = github_file_records(files)
    assets = remote.get("assets")
    require(isinstance(assets, list) and all(isinstance(item, dict) for item in assets),
            "Invalid release asset inventory")
    names = [item.get("name") for item in assets]
    require(all(isinstance(name, str) and name for name in names) and len(names) == len(set(names)),
            "Invalid or duplicate release asset names")
    ordinary = set(names) - set(optional)
    require(ordinary <= set(expected) and (partial or ordinary == set(expected)), "Release files differ from the build")
    for item in assets:
        if item["name"] not in expected:
            continue
        record = expected[item["name"]]
        require(item.get("state") == "uploaded" and item.get("size") == record["bytes"]
                and item.get("digest") == "sha256:" + record["sha256"],
                "Release package differs from the original build: " + item["name"])
    return set(expected) - ordinary


def safe_names(names):
    normalized = {}
    for name in names:
        clean = name.removeprefix("./").replace("\\", "/")
        require(not clean.startswith("/") and ".." not in clean.split("/"), "Unsafe package member: " + name)
        require(clean not in normalized, "Duplicate package member: " + clean)
        normalized[clean] = name
    return normalized


@contextmanager
def zip_reader(path):
    with zipfile.ZipFile(path) as archive:
        names = safe_names(archive.namelist())
        require(archive.testzip() is None, "Corrupt ZIP package: " + path.name)
        yield lambda name: archive.read(names[name]), set(names)


def text(data):
    return data.decode("utf-8-sig").replace("\r\n", "\n")


def check_payload(read, names, prefix, root, context, *, font=False):
    for name in ("pubspec.yaml", "CHANGELOG.md"):
        expected = text(git_blob(root, context["source_commit"], name))
        if name == "pubspec.yaml" and font:
            patch = text(git_blob(root, context["source_commit"], "patch/font.dart"))
            require(FONT_PATCH in patch and expected.count("# fonts:") == 1, "Unreviewed Linux ARM64 font patch")
            expected = expected.replace("# fonts:", FONT_PATCH, 1)
        require(text(read(prefix + name)) == expected, "Embedded source file differs: " + name)
    notice_name = Path(NOTICE_SOURCE).name
    notices = [name for name in names if name.rsplit("/", 1)[-1] == notice_name]
    expected_notice = git_blob(root, context["source_commit"], NOTICE_SOURCE)
    require(notices and all(text(read(name)) == text(expected_notice) for name in notices), "Packaged native library notice differs")
    if font:
        require(prefix + FONT_ASSET in names and read(prefix + FONT_ASSET)[:4] in (b"\0\1\0\0", b"OTTO"),
                "Linux ARM64 font asset is missing or invalid")
        manifest = json.loads(read(prefix + "FontManifest.json"))
        require([entry for entry in manifest if entry.get("family") == "HarmonyOS Sans"] ==
                [{"family": "HarmonyOS Sans", "fonts": [{"asset": FONT_ASSET}]}],
                "Linux ARM64 font manifest differs from the packaged font")


def check_elf(data, machine):
    require(len(data) >= 20 and data[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", data, 18)[0] == machine,
            "Incorrect ELF architecture")


def check_pe(data, machines):
    require(len(data) >= 64 and data[:2] == b"MZ", "Invalid Windows executable")
    offset = struct.unpack_from("<I", data, 60)[0]
    require(len(data) >= offset + 6 and data[offset:offset + 4] == b"PE\0\0"
            and struct.unpack_from("<H", data, offset + 4)[0] in machines, "Incorrect Windows PE architecture")


def macho_architectures(data):
    require(len(data) >= 8, "Invalid Mach-O executable")
    magic = data[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        return {struct.unpack_from("<I" if magic[0] == 0xcf else ">I", data, 4)[0]}
    require(magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"), "Invalid Mach-O architecture header")
    count = struct.unpack_from(">I", data, 4)[0]
    stride = 32 if magic[-1] == 0xbf else 20
    require(0 < count <= 8 and len(data) >= 8 + count * stride, "Invalid universal Mach-O executable")
    return {struct.unpack_from(">I", data, 8 + index * stride)[0] for index in range(count)}


def apple_bundle(read, names, prefix, assets, root, context, *, ios):
    info = plistlib.loads(read(prefix + "Info.plist" if ios else prefix + "Contents/Info.plist"))
    # iOS passes an explicit numeric base version; Flutter normalizes macOS RC names to digits/dots.
    native_version = context["version"].split("-")[0] if ios else re.sub(r"[^\d.]", "", context["version"])
    require(str(info.get("CFBundleShortVersionString")) == native_version
            and str(info.get("CFBundleVersion")) == str(context["build"]), "Incorrect Apple native version")
    executable = prefix + ("" if ios else "Contents/MacOS/") + info["CFBundleExecutable"]
    architectures = macho_architectures(read(executable))
    require(architectures == {0x100000c} if ios else bool(architectures) and architectures <= {0x1000007, 0x100000c},
            "Incorrect Apple executable architecture")
    check_payload(read, names, assets, root, context)


def check_deb(path, arch, root, context):
    members = {}
    with path.open("rb") as stream:
        require(stream.read(8) == b"!<arch>\n", "Invalid Debian container")
        while header := stream.read(60):
            require(len(header) == 60 and header[58:] == b"`\n", "Invalid Debian ar header")
            name, size = header[:16].decode().strip().rstrip("/"), int(header[48:58].decode().strip())
            require(name not in members and 0 < size <= path.stat().st_size, "Invalid Debian ar member")
            members[name] = stream.read(size)
            require(len(members[name]) == size, "Truncated Debian ar member")
            if size % 2:
                stream.read(1)
    require(members.get("debian-binary") == b"2.0\n", "Invalid Debian format")
    for category in ("control", "data"):
        matches = [name for name in members if name.startswith(category + ".tar")]
        require(len(matches) == 1, "Missing Debian tar member")
        with tarfile.open(fileobj=io.BytesIO(members[matches[0]]), mode="r:*") as archive:
            names = safe_names(archive.getnames())
            read = lambda name: archive.extractfile(names[name]).read()
            if category == "control":
                fields = dict(re.findall(r"^(Package|Version|Architecture): (.+)$", read("control").decode(), re.M))
                require(fields == {"Package": "venera-next", "Version": versions(context["version"])[0], "Architecture": arch},
                        "Incorrect Debian package identity/version/architecture")
            else:
                # The DEB install path is an upgrade contract, independently checked here.
                prefix = "usr/local/lib/venera-next/"
                check_elf(read(prefix + "venera-next"), 62 if arch == "amd64" else 183)
                check_payload(read, set(names), prefix + "data/flutter_assets/", root, context, font=arch == "arm64")


def check_linux_archive(path, machine, root, context):
    names = safe_names(subprocess.check_output(["bsdtar", "-tf", str(path)], timeout=60).decode().splitlines())
    read = lambda name: subprocess.check_output(["bsdtar", "-xOf", str(path), names[name]], timeout=60)
    if path.suffix == ".rpm":
        fields = subprocess.check_output(["rpm", "-qp", "--qf", "%{NAME}\n%{VERSION}\n%{RELEASE}\n%{ARCH}\n", str(path)], timeout=30).decode().splitlines()
        require(fields == ["venera-next", versions(context["version"])[0], str(context["build"]), machine],
                "Incorrect RPM package identity/version/architecture")
        prefix = "opt/venera-next/"
    else:
        info = dict(re.findall(r"^(pkgname|pkgver|arch) = (.+)$", read(".PKGINFO").decode(), re.M))
        require(info == {"pkgname": "venera-next", "pkgver": f"{context['version'].replace('-', '_')}-{context['build']}", "arch": machine},
                "Incorrect Arch package identity/version/architecture")
        prefix = "usr/bin/venera-next_pkg/"
    check_elf(read(prefix + "venera-next"), 62 if machine == "x86_64" else 183)
    check_payload(read, set(names), prefix + "data/flutter_assets/", root, context, font=machine == "aarch64")


def directory_reader(directory):
    names = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
    return lambda name: (directory / name).read_bytes(), names


def check_platform(platform, paths, root, context, environ):
    if platform.startswith("android_"):
        flavor = platform.removeprefix("android_")
        metadata = android.build_metadata(flavor, text(git_blob(root, context["source_commit"], "pubspec.yaml")), environ)
        catalog = json.loads(paths[f"android-{flavor}-manifest.json"].read_text())
        android.verify_release_flavor(paths, catalog, metadata)
        for abi in android.ABI_CODES:
            path = paths[android.apk_filename(metadata, abi)]
            android.validate_contents(path, catalog, abi)
            with zip_reader(path) as (read, names):
                check_payload(read, names, "assets/flutter_assets/", root, context)
    elif platform == "windows":
        path = paths[f"VeneraNext-{context['version']}-windows.zip"]
        with zip_reader(path) as (read, names):
            prefix = path.stem + "/"
            require(all(name.startswith(prefix) for name in names), "Incorrect portable ZIP root")
            check_pe(read(prefix + "VeneraNext.exe"), {0x8664})
            check_payload(read, names, prefix + "data/flutter_assets/", root, context)
        check_pe(paths[f"VeneraNext-{context['version']}-windows-installer.exe"].read_bytes(), {0x14c, 0x8664})
    elif platform == "ios":
        with zip_reader(next(iter(paths.values()))) as (read, names):
            apple_bundle(read, names, "Payload/Runner.app/", "Payload/Runner.app/Frameworks/App.framework/flutter_assets/",
                         root, context, ios=True)
    elif platform == "macos":
        with tempfile.TemporaryDirectory(prefix="venera-dmg-") as temporary:
            mount = Path(temporary) / "mounted"
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(next(iter(paths.values())))],
                           check=True, stdout=subprocess.DEVNULL, timeout=120)
            try:
                apps = list(mount.glob("*.app"))
                require(len(apps) == 1, "Expected one application in the DMG")
                read, names = directory_reader(apps[0])
                apple_bundle(read, names, "", "Contents/Frameworks/App.framework/Resources/flutter_assets/", root, context, ios=False)
            finally:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True, timeout=60)
    else:
        machine = "x86_64" if platform == "linux_x64" else "aarch64"
        for path in paths.values():
            if path.suffix == ".deb":
                check_deb(path, "amd64" if machine == "x86_64" else "arm64", root, context)
            elif path.suffix == ".AppImage":
                with path.open("rb") as stream:
                    header = stream.read(64)
                check_elf(header, 62 if machine == "x86_64" else 183)
                require(header[8:11] == b"AI\x02", "Invalid AppImage format")
                with tempfile.TemporaryDirectory(prefix="venera-appimage-") as temporary:
                    subprocess.run([str(path.resolve()), "--appimage-extract"], cwd=temporary, check=True,
                                   stdout=subprocess.DEVNULL, timeout=120)
                    read, names = directory_reader(Path(temporary) / "squashfs-root")
                    check_payload(read, names, "usr/lib/venera-next/data/flutter_assets/", root, context, font=machine == "aarch64")
            else:
                check_linux_archive(path, machine, root, context)


def locate_files(directories, expected):
    paths = {}
    for directory in directories:
        require(directory.is_dir() and not directory.is_symlink(), "Missing package directory: " + str(directory))
        for path in directory.iterdir():
            if path.name in expected:
                require(path.name not in paths, "Duplicate release package: " + path.name)
                paths[path.name] = path
    require(set(paths) == set(expected), "Missing release packages: " + ", ".join(sorted(set(expected) - set(paths))))
    return paths


def aggregate(directory, receipts, context):
    expected = expected_files(context)
    paths = {path.name: path for path in directory.iterdir() if path.is_file()}
    names = set().union(*expected.values())
    require(set(paths) == names, "Missing or unexpected full-build release packages")
    records = file_records(paths.values())
    checks = {}
    for platform in PLATFORMS:
        receipt = json.loads((receipts / f"{platform}.json").read_text())
        require(all(receipt.get(key) == value for key, value in context.items()) and receipt.get("platform") == platform
                and receipt.get("contents_verified") is True, "Wrong compiler source or incomplete receipt: " + platform)
        require(receipt.get("files") == {name: records[name] for name in expected[platform]},
                "Package bytes differ from the compiler receipt: " + platform)
        checks[platform] = "pass"
    return context | {"files": records, "github_files": github_file_records(records), "package_checks": checks}


def write_receipt(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("platform", "aggregate"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--platform", choices=PLATFORMS)
    parser.add_argument("--directory", type=Path, action="append", required=True)
    parser.add_argument("--receipts", type=Path)
    parser.add_argument("--security-report", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    context = source_context(args.root, os.environ)
    if args.action == "platform":
        if args.platform is None:
            parser.error("--platform is required")
        paths = locate_files(args.directory, expected_files(context)[args.platform])
        check_platform(args.platform, paths, args.root, context, os.environ)
        result = context | {"platform": args.platform, "contents_verified": True, "files": file_records(paths.values())}
    else:
        if args.receipts is None or len(args.directory) != 1:
            parser.error("aggregate requires one --directory and --receipts")
        result = aggregate(args.directory[0], args.receipts, context)
        if args.security_report:
            from release_security import check_report
            result["security"] = check_report(json.loads(args.security_report.read_text()), args.root, context)
    write_receipt(args.receipt, result)
    print(f"Verified {len(result['files'])} packages from {context['source_commit']}")


if __name__ == "__main__":
    main()
