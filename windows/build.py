import argparse
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_BUILD_DIR = ROOT / "build" / "windows"
WINDOWS_ICON_PATH = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
CHINESE_TRANSLATION_PATH = ROOT / "windows" / "ChineseSimplified.isl"
CHINESE_TRANSLATION_URL = (
    "https://cdn.jsdelivr.net/gh/kira-96/"
    "Inno-Setup-Chinese-Simplified-Translation@"
    "1ace6a485174288c7416d0979cc2db1f0990f95a/ChineseSimplified.isl"
)
CHINESE_TRANSLATION_SHA256 = (
    "bc76580176cba3303fb4b0edfd4c65557cc57dad09d1efc3f8d16557c0f2d694"
)


def run(command):
    executable = shutil.which(command[0])
    if executable is None:
        raise FileNotFoundError(command[0])
    subprocess.run([executable, *command[1:]], check=True, cwd=ROOT)


def read_version():
    content = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s]+)", content, re.MULTILINE)
    if match is None:
        raise RuntimeError("pubspec.yaml does not contain a version field")
    version = match.group(1).split("+", 1)[0]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError(f"Unsafe package version: {version}")
    return version


def require_non_empty_file(path):
    if not path.is_file():
        raise FileNotFoundError(path)
    if path.stat().st_size <= 0:
        raise RuntimeError(f"{path} is empty")


def architecture_paths(arch):
    if arch not in ("x64", "arm64"):
        raise ValueError(f"Unsupported Windows architecture: {arch}")
    runner = WINDOWS_BUILD_DIR / arch / "runner"
    suffix = "windows" if arch == "x64" else "windows-arm64"
    template = ROOT / "windows" / ("build.iss" if arch == "x64" else "build_arm64.iss")
    return runner, suffix, template


def remove_build_directory(path):
    # Resolve before recursive deletion, including junctions and symlinks.
    resolved = path.resolve()
    build_root = WINDOWS_BUILD_DIR.resolve()
    if resolved == build_root or not resolved.is_relative_to(build_root):
        raise ValueError(f"Build cleanup escapes its root: {path}")
    if path.exists():
        shutil.rmtree(path)


def clean_windows_runner_build(arch="x64"):
    runner, _, _ = architecture_paths(arch)
    remove_build_directory(runner)


def create_portable_zip(version, arch="x64"):
    runner, suffix, _ = architecture_paths(arch)
    release_dir = runner / "Release"
    if not release_dir.is_dir():
        raise FileNotFoundError(release_dir)

    zip_path = WINDOWS_BUILD_DIR / f"VeneraNext-{version}-{suffix}.zip"
    package_dir = WINDOWS_BUILD_DIR / f"VeneraNext-{version}-{suffix}"
    if zip_path.exists():
        zip_path.unlink()
    if package_dir.exists():
        remove_build_directory(package_dir)

    try:
        shutil.copytree(release_dir, package_dir)
        shutil.make_archive(
            str(zip_path.with_suffix("")),
            "zip",
            WINDOWS_BUILD_DIR,
            package_dir.name,
        )
        require_non_empty_file(zip_path)
        return zip_path
    finally:
        if package_dir.exists():
            remove_build_directory(package_dir)


def validate_icon_resources():
    require_non_empty_file(WINDOWS_ICON_PATH)


def ensure_chinese_translation():
    if CHINESE_TRANSLATION_PATH.exists():
        return

    request = Request(
        CHINESE_TRANSLATION_URL,
        headers={"User-Agent": "VeneraNext-Windows-Build"},
    )
    with urlopen(request, timeout=30) as response:
        content = response.read()
    if not content:
        raise RuntimeError("Downloaded ChineseSimplified.isl is empty")
    digest = hashlib.sha256(content).hexdigest()
    if digest != CHINESE_TRANSLATION_SHA256:
        raise RuntimeError(
            "Downloaded ChineseSimplified.isl failed SHA256 verification: "
            f"{digest}"
        )

    temporary_path = CHINESE_TRANSLATION_PATH.with_suffix(".isl.tmp")
    temporary_path.write_bytes(content)
    temporary_path.replace(CHINESE_TRANSLATION_PATH)


def build_installer(version, arch="x64"):
    _, suffix, iss_path = architecture_paths(arch)
    iss_content = iss_path.read_bytes()
    rendered = iss_content.decode("utf-8").replace("{{version}}", version)
    rendered = rendered.replace("{{root_path}}", str(ROOT))
    installer_path = WINDOWS_BUILD_DIR / f"VeneraNext-{version}-{suffix}-installer.exe"

    if installer_path.exists():
        installer_path.unlink()

    try:
        iss_path.write_text(rendered, encoding="utf-8")
        ensure_chinese_translation()
        run(["iscc", str(iss_path)])
    finally:
        iss_path.write_bytes(iss_content)

    require_non_empty_file(installer_path)
    return installer_path


def main(arch="x64"):
    architecture_paths(arch)
    version = read_version()
    validate_icon_resources()
    clean_windows_runner_build(arch)
    command = ["flutter", "build", "windows"]
    if arch == "arm64":
        command += ["--target-platform", "windows-arm64"]
    run(command)
    create_portable_zip(version, arch)
    build_installer(version, arch)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build Windows release packages")
    parser.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    main(parser.parse_args().arch)
