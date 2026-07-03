import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / "release.json"
PUBSPEC_PATH = ROOT / "pubspec.yaml"
CHANGELOG_PATH = ROOT / "CHANGELOG.md"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-rc\.\d+)?$")


class ReleaseVersionError(RuntimeError):
    pass


def _read(path: Path) -> str:
    return path.read_bytes().decode("utf-8-sig")


def _write(path: Path, text: str) -> None:
    raw = path.read_bytes() if path.exists() else b""
    has_bom = raw.startswith(b"\xef\xbb\xbf")
    newline = "\r\n" if b"\r\n" in raw else "\n"
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if newline != "\n":
        normalized = normalized.replace("\n", newline)
    data = normalized.encode("utf-8")
    if has_bom:
        data = b"\xef\xbb\xbf" + data
    path.write_bytes(data)


def load_release_config() -> dict:
    try:
        config = json.loads(_read(CONFIG_PATH))
    except FileNotFoundError as error:
        raise ReleaseVersionError("release.json is missing") from error
    except json.JSONDecodeError as error:
        raise ReleaseVersionError(f"release.json is invalid JSON: {error}") from error

    version = config.get("version")
    build = config.get("build")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ReleaseVersionError(
            "release.json version must look like 1.2.3 or 1.2.3-rc.1"
        )
    if not isinstance(build, int) or build <= 0:
        raise ReleaseVersionError("release.json build must be a positive integer")
    return {"version": version, "build": build}


def release_tag(config: dict) -> str:
    return f"v{config['version']}"


def pubspec_version(config: dict) -> str:
    return f"{config['version']}+{config['build']}"


def _pubspec_version_line() -> re.Pattern:
    return re.compile(r"^version:\s*(?P<version>\S+)\s*$", re.MULTILINE)


def sync_pubspec(config: dict) -> bool:
    text = _read(PUBSPEC_PATH)
    pattern = _pubspec_version_line()
    expected = pubspec_version(config)
    match = pattern.search(text)
    if not match:
        raise ReleaseVersionError("pubspec.yaml does not contain a version field")
    if match.group("version") == expected:
        return False
    updated = pattern.sub(f"version: {expected}", text, count=1)
    _write(PUBSPEC_PATH, updated)
    return True


def sync_changelog_heading(config: dict) -> bool:
    text = _read(CHANGELOG_PATH)
    tag = release_tag(config)
    if re.search(rf"^##\s+{re.escape(tag)}\s*$", text, re.MULTILINE):
        return False
    updated = re.sub(
        r"^##\s+(?:未发布|Unreleased)\s*$",
        f"## {tag}",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if updated == text:
        raise ReleaseVersionError(
            f"CHANGELOG.md must contain a section for {tag} or an Unreleased section"
        )
    _write(CHANGELOG_PATH, updated)
    return True


def check_release_files(tag: str | None = None) -> None:
    config = load_release_config()
    expected_tag = release_tag(config)
    if tag is not None and tag != expected_tag:
        raise ReleaseVersionError(
            f"tag {tag} does not match release.json tag {expected_tag}"
        )

    pubspec_text = _read(PUBSPEC_PATH)
    match = _pubspec_version_line().search(pubspec_text)
    if not match:
        raise ReleaseVersionError("pubspec.yaml does not contain a version field")
    expected_pubspec = pubspec_version(config)
    actual_pubspec = match.group("version")
    if actual_pubspec != expected_pubspec:
        raise ReleaseVersionError(
            f"pubspec.yaml version {actual_pubspec} does not match "
            f"release.json version {expected_pubspec}"
        )

    if not re.search(r"^\s+-\s+pubspec\.yaml\s*$", pubspec_text, re.MULTILINE):
        raise ReleaseVersionError(
            "pubspec.yaml must be listed in flutter assets so App.version can read it"
        )

    changelog_text = _read(CHANGELOG_PATH)
    if not re.search(
        rf"^##\s+{re.escape(expected_tag)}\s*$",
        changelog_text,
        re.MULTILINE,
    ):
        raise ReleaseVersionError(
            f"CHANGELOG.md does not contain a section for {expected_tag}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="sync pubspec and changelog")
    parser.add_argument("--check", action="store_true", help="check synchronized files")
    parser.add_argument("--tag", help="validate an expected release tag")
    args = parser.parse_args()

    try:
        config = load_release_config()
        if args.write:
            changed = [
                sync_pubspec(config),
                sync_changelog_heading(config),
            ]
            if any(changed):
                print(f"Release files synchronized for {release_tag(config)}")
            else:
                print(f"Release files already synchronized for {release_tag(config)}")
        if args.check or not args.write:
            check_release_files(args.tag)
            print(f"Release files are synchronized for {release_tag(config)}")
    except ReleaseVersionError as error:
        print(f"::error::{error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
