"""Prepare the real application in an isolated, locked OHOS build directory."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

from native_build import CONFIG, ROOT, digest, require_within
from prepare_probe import (BASE, command, configure_device_types, configure_profile,
                           export_qjs, verify_native_report)


FULL_CONFIG_PATH = Path(__file__).with_name("full_app_config.json")
FULL_CONFIG = json.loads(FULL_CONFIG_PATH.read_text(encoding="utf-8"))
DEPS = BASE / "full-deps"
PROJECT = BASE / "full-app"
WEBVIEW_PACKAGES = tuple("flutter_inappwebview" + suffix for suffix in (
    "", "_platform_interface", "_ohos", "_android", "_ios", "_macos", "_web", "_windows"))
EXTRA_LIBRARIES = ("liblodepng_flutter.so", "libzip_flutter.so", "libflutter_7zip.so")


def tree_digest(root):
    result = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if (set(relative.parts) & {".git", ".dart_tool", "oh_modules", ".hvigor", "build"} or
                path.name in ("pubspec.lock", "oh-package-lock.json5", "flutter.har")):
            continue
        if path.is_symlink():
            raise ValueError("Unexpected dependency symlink")
        if path.is_file():
            result.update(path.relative_to(root).as_posix().encode() + b"\0")
            result.update(path.read_bytes())
    return result.hexdigest()


def patch_once(text, original, replacement):
    if text.count(original) != 1:
        raise ValueError("Pinned dependency changed; review the OHOS patch")
    return text.replace(original, replacement)


def patch_so_loader(text):
    return patch_once(text, "if (Platform.isAndroid || Platform.isLinux) {",
                      "if (Platform.isAndroid || Platform.isLinux || "
                      "Platform.operatingSystem == 'ohos') {")


def patch_sqlite_loader(text):
    if "Platform.operatingSystem == 'ohos'" in text:
        raise ValueError("SQLite OHOS loader must only be applied once")
    return patch_once(text, "DynamicLibrary _defaultOpen() {",
                      "DynamicLibrary _defaultOpen() {\n"
                      "  if (Platform.operatingSystem == 'ohos') {\n"
                      "    return DynamicLibrary.open('libsqlite3.so');\n  }")


def patch_pdfium_hook(text):
    # Explicitly unsupported feature: do not fetch an Android/Linux PDFium binary.
    if "OS.ohos" in text:
        raise ValueError("PDFium's unsupported OHOS boundary must only be applied once")
    return patch_once(text, "if (!input.config.buildCodeAssets) return;",
                      "if (!input.config.buildCodeAssets) return;\n"
                      "    if (input.config.code.targetOS == OS.ohos) return;")


def extract_checked(archive, destination):
    destination = require_within(destination, BASE)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        for item in package.getmembers():
            require_within(destination / item.name, destination)
            if not (item.isfile() or item.isdir()):
                raise ValueError("Unexpected dependency archive link or special file")
        package.extractall(destination, filter="data")


def export_git(name, spec):
    repository = require_within(BASE / "full-repositories" / name, BASE)
    if not (repository / ".git").exists():
        if repository.exists():
            raise ValueError("Refusing an unknown dependency checkout")
        command(["git", "clone", "--filter=blob:none", "--no-checkout", spec["repository"], repository])
        command(["git", "-C", repository, "fetch", "--depth", "1", "origin", spec["ref"]])
        command(["git", "-C", repository, "checkout", "--detach", "FETCH_HEAD"])
    head = subprocess.check_output(["git", "-C", repository, "rev-parse", "HEAD"], text=True).strip()
    if head != spec["revision"]:
        raise ValueError(f"Unexpected pinned {name} revision")
    command(["git", "-C", repository, "diff", "--exit-code", "HEAD"])
    archive = BASE / f"full-{name}.tar"
    command(["git", "-C", repository, "archive", "--format=tar", f"--output={archive}", head])
    destination = DEPS / name
    extract_checked(archive, destination)
    return destination


def check_hosted_baseline(name, spec, text):
    block = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  \w+:|^sdks:)", text, re.M | re.S)
    if not block:
        raise ValueError(f"Missing main dependency {name}")
    version = re.search(r'    version: "([^"\n]+)"', block[1])
    checksum = re.search(r'      sha256: "?([0-9a-f]{64})"?', block[1])
    if not version or not checksum or version[1] != spec["version"] or checksum[1] != spec["sha256"]:
        raise ValueError(f"Main {name} lock changed; update the experiment explicitly")


def export_hosted(name, spec):
    check_hosted_baseline(name, spec, (ROOT / "pubspec.lock").read_text(encoding="utf-8"))
    archive = BASE / f"full-{name}-{spec['version']}.tar.gz"
    if not archive.exists():
        download = archive.with_suffix(".download")
        command(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                 "--retry-all-errors", "--max-time", "300", "--output", download,
                 f"https://pub.dev/api/archives/{name}-{spec['version']}.tar.gz"])
        if digest(download) != spec["sha256"]:
            raise ValueError(f"Changed hosted archive for {name}")
        download.replace(archive)
    if digest(archive) != spec["sha256"]:
        raise ValueError(f"Changed hosted archive for {name}")
    destination = DEPS / name
    extract_checked(archive, destination)
    return destination


def prepare_dependencies(qjs_source):
    DEPS.mkdir(parents=True, exist_ok=True)
    records = {}
    for name in ("webview", "code_assets", "lodepng_flutter", "flutter_7zip"):
        spec = FULL_CONFIG[name]
        root = export_git(name, spec)
        records[name] = {"revision": spec["revision"], "original_sha256": tree_digest(root)}
    for name, spec in FULL_CONFIG["hosted"].items():
        root = export_hosted(name, spec)
        records[name] = {**spec, "original_sha256": tree_digest(root)}
    export_qjs(qjs_source, BASE / "deps/flutter_qjs")
    for name, loader in (("lodepng_flutter", "lib/lodepng_flutter.dart"),
                         ("flutter_7zip", "lib/flutter_7zip.dart"),
                         ("zip_flutter", "lib/src/zip_dart_base.dart")):
        path = DEPS / name / loader
        path.write_text(patch_so_loader(path.read_text(encoding="utf-8")), encoding="utf-8")
    path = DEPS / "sqlite3/lib/src/ffi/load_library.dart"
    path.write_text(patch_sqlite_loader(path.read_text(encoding="utf-8")), encoding="utf-8")
    path = DEPS / "pdfium_dart/hook/build.dart"
    path.write_text(patch_pdfium_hook(path.read_text(encoding="utf-8")), encoding="utf-8")
    for path in [DEPS / "pdfium_dart/pubspec.yaml", DEPS / "code_assets/pkgs/code_assets/pubspec.yaml"]:
        path.write_text(patch_once(path.read_text(encoding="utf-8"), "resolution: workspace\n", ""),
                        encoding="utf-8")
    for name in records:
        records[name]["prepared_sha256"] = tree_digest(DEPS / name)
    records["flutter_qjs"] = {"revision": CONFIG["quickjs"]["revision"],
                              "prepared_sha256": tree_digest(BASE / "deps/flutter_qjs")}
    (DEPS / "sources.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    return records


def verify_dependencies():
    records = json.loads((DEPS / "sources.json").read_text(encoding="utf-8"))
    for name, record in records.items():
        root = BASE / "deps/flutter_qjs" if name == "flutter_qjs" else DEPS / name
        if tree_digest(root) != record["prepared_sha256"]:
            raise ValueError(f"Prepared dependency changed: {name}")
    return records


def configure_pubspec(text):
    text = re.sub(r"^version: .*?$", f"version: {FULL_CONFIG['version_name']}+{FULL_CONFIG['version_code']}",
                  text, count=1, flags=re.M)
    for name in ("photo_view", "share_plus", "rhttp"):
        text = patch_once(text, f"path: packages/{name}", f"path: ../../../packages/{name}")
    overrides = {
        "flutter_qjs": "../deps/flutter_qjs",
        **{name: f"../full-deps/{name}" for name in ("sqlite3", "zip_flutter", "lodepng_flutter", "flutter_7zip", "pdfium_dart")},
        "code_assets": "../full-deps/code_assets/pkgs/code_assets",
        **{name: f"../full-deps/webview/{name}" for name in WEBVIEW_PACKAGES},
    }
    lines = "".join(f"  {name}:\n    path: {path}\n" for name, path in overrides.items())
    text = patch_once(text, "dependency_overrides:\n", "dependency_overrides:\n" + lines)
    text = patch_once(text, "    - assets/translation.json\n",
                      "    - assets/translation.json\n    - assets/harmonyos-app-build.json\n")
    return text


def app_source_manifest():
    files = [ROOT / "pubspec.yaml", ROOT / "pubspec.lock", ROOT / "CHANGELOG.md"]
    files.extend(sorted((ROOT / "lib").rglob("*.dart")))
    files.extend(sorted(path for path in (ROOT / "assets").rglob("*") if path.is_file()))
    return {path.relative_to(ROOT).as_posix(): digest(path) for path in files}


def prepare_project(args):
    sdk = args.flutter_sdk.resolve()
    head = subprocess.check_output(["git", "-C", sdk, "rev-parse", "HEAD"], text=True).strip()
    if head != CONFIG["flutter"]["revision"]:
        raise ValueError("Unexpected Flutter OH toolchain")
    project = require_within(PROJECT, BASE)
    flutter = sdk / ("bin/flutter.bat" if os.name == "nt" else "bin/flutter")
    if not (project / ".metadata").exists():
        if project.exists() and any(project.iterdir()):
            raise ValueError("Refusing to overwrite an unknown application directory")
        command([flutter, "create", "--platforms", "ohos", "--no-pub", "--org",
                 "com.github.cyrilpeng", "--project-name", "venera_next", project])
        (project / ".venera-harmonyos-owned").write_text("generated full app\n", encoding="utf-8")
    if not (project / ".venera-harmonyos-owned").exists():
        raise ValueError("Missing generated-project ownership marker")
    records = verify_dependencies()
    for name in ("lib", "assets", "test"):
        destination = require_within(project / name, project)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / name, destination)
    # Only relocate repository-relative test imports; runtime source is unchanged.
    for name, original, source in (
        ("test/foundation/photo_view_controller_lifecycle_test.dart",
         "../../packages/photo_view/test/controller_lifecycle_test.dart",
         ROOT / "packages/photo_view/test/controller_lifecycle_test.dart"),
        ("test/tool/git_dependencies_test.dart", "../../tool/check_git_dependencies.dart",
         ROOT / "tool/check_git_dependencies.dart"),
    ):
        path = project / name
        relocated = os.path.relpath(source, path.parent).replace("\\", "/")
        path.write_text(patch_once(path.read_text(encoding="utf-8"), original, relocated), encoding="utf-8")
    (project / "pubspec.yaml").write_text(configure_pubspec((ROOT / "pubspec.yaml").read_text(encoding="utf-8")), encoding="utf-8")
    shutil.copy2(ROOT / "CHANGELOG.md", project / "CHANGELOG.md")
    shutil.copy2(ROOT / "LICENSE", project / "LICENSE")
    shutil.copy2(ROOT / "analysis_options.yaml", project / "analysis_options.yaml")
    lock = Path(__file__).with_name("app") / "pubspec.lock.template"
    if lock.exists():
        shutil.copy2(lock, project / "pubspec.lock")
    elif not args.resolve_lock:
        raise ValueError("Missing reviewed full-app lock; only development may resolve it")
    else:
        shutil.copy2(ROOT / "pubspec.lock", project / "pubspec.lock")
    for template in Path(__file__).with_name("app").rglob("*.template"):
        if template.name == "pubspec.lock.template":
            continue
        destination = require_within(project / template.relative_to(Path(__file__).with_name("app")).with_suffix(""), project)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(template, destination)
    profile = project / "ohos/build-profile.json5"
    profile.write_text(configure_profile(profile.read_text(encoding="utf-8"), CONFIG["harmonyCiSdk"]["targetSdk"]), encoding="utf-8")
    module = project / "ohos/entry/src/main/module.json5"
    module.write_text(configure_device_types(module.read_text(encoding="utf-8")), encoding="utf-8")
    app_json = project / "ohos/AppScope/app.json5"
    app = json.loads(app_json.read_text(encoding="utf-8"))
    app["app"].update(bundleName=FULL_CONFIG["bundle_name"], versionName=FULL_CONFIG["hap_version_name"],
                       versionCode=FULL_CONFIG["version_code"], vendor="CyrilPeng")
    app_json.write_text(json.dumps(app, indent=2) + "\n", encoding="utf-8")
    entry_profile = project / "ohos/entry/build-profile.json5"
    entry_profile.write_text(json.dumps({"apiType": "stageMode", "buildOption": {
        "nativeLib": {"debugSymbol": {"strip": False, "exclude": []}}}, "targets": [
        {"name": "default", "runtimeOS": "HarmonyOS"}, {"name": "ohosTest"}]}, indent=2) + "\n", encoding="utf-8")
    for root in (project / "ohos/AppScope/resources/base", project / "ohos/entry/src/main/resources/base"):
        strings = root / "element/string.json"
        data = json.loads(strings.read_text(encoding="utf-8"))
        for item in data["string"]:
            if item["name"] in ("app_name", "EntryAbility_label"):
                item["value"] = "VeneraNext (HarmonyOS Lab)"
        strings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        for name in ("app_icon.png", "icon.png"):
            if (root / "media" / name).exists():
                shutil.copy2(ROOT / "assets/app_icon.png", root / "media" / name)
    native = verify_native_report(args.native_dir / "native-build.json", args.native_dir / "arm64-v8a")
    extras = json.loads((args.extra_native_dir / "extra-native-build.json").read_text(encoding="utf-8"))
    if (extras.get("status") != "cross_compile_pass" or extras.get("dependencies") != records or
            extras.get("build_script_sha256") != digest(Path(__file__).with_name("full_native_build.py")) or
            any(extras.get(key) != native.get(key) for key in ("sdk_profile", "sdk_version", "sdk_api"))):
        raise ValueError("Full app needs matching, audited extra native libraries")
    destination = project / "ohos/entry/libs/arm64-v8a"
    destination.mkdir(parents=True, exist_ok=True)
    expected = {item["name"]: item["sha256"] for item in native["libraries"]}
    if set(item["name"] for item in extras["libraries"]) != set(EXTRA_LIBRARIES):
        raise ValueError("Missing complete reader native libraries")
    for item in extras["libraries"]:
        source = args.extra_native_dir / "arm64-v8a" / item["name"]
        if digest(source) != item["sha256"]:
            raise ValueError("Changed extra native library")
        shutil.copy2(source, destination / source.name)
        expected[source.name] = item["sha256"]
    for name in ("librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so"):
        shutil.copy2(args.native_dir / "arm64-v8a" / name, destination / name)
    metadata = {
        "schema": 1, "purpose": "full_reader_experiment", "branch": "HarmonyOS",
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "bundle_name": FULL_CONFIG["bundle_name"], "version_name": FULL_CONFIG["version_name"],
        "hap_version_name": FULL_CONFIG["hap_version_name"],
        "version_code": FULL_CONFIG["version_code"], "device_types": ["phone", "tablet"],
        "minimum_sdk": "26.0.0", "entrypoint": "lib/main.dart", "reader_integrated": True,
        "runtime_verified": False, "signed": False, "unavailable": FULL_CONFIG["unavailable"],
        "source_files": app_source_manifest(), "dependencies": records, "native_libraries": expected,
        "bundled_assets": {
            name: digest(ROOT / name) for name in re.findall(
                r"^    - (assets/[^\r\n]+)$", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
        },
    }
    (project / "assets/harmonyos-app-build.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    pub_args = ["pub", "get"] + ([] if args.resolve_lock else ["--enforce-lockfile"])
    if args.offline:
        pub_args.append("--offline")
    env = os.environ.copy()
    env["PUB_HOSTED_URL"] = "https://pub.dev"
    if args.dart_only:
        env["FLUTTER_ROOT"] = str(sdk)
        dart = sdk / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt" else "bin/cache/dart-sdk/bin/dart")
        command([dart, *pub_args], cwd=project, env=env)
        print("Dart-only preparation does not verify plugin registration or a HAP.")
    else:
        command([flutter, *pub_args], cwd=project, env=env)
    print(f"Prepared real entrypoint {project / 'lib/main.dart'}; no device runtime is claimed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("deps", "project"))
    parser.add_argument("--flutter-sdk", type=Path)
    parser.add_argument("--qjs-source", type=Path)
    parser.add_argument("--native-dir", type=Path, default=BASE / "native")
    parser.add_argument("--extra-native-dir", type=Path, default=BASE / "full-native")
    parser.add_argument("--dart-only", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--resolve-lock", action="store_true")
    args = parser.parse_args()
    if args.stage == "deps":
        if args.qjs_source is None:
            parser.error("deps requires --qjs-source")
        prepare_dependencies(args.qjs_source.resolve())
    else:
        if args.flutter_sdk is None:
            parser.error("project requires --flutter-sdk")
        prepare_project(args)


if __name__ == "__main__":
    main()
