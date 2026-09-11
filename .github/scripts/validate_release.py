import argparse
import os
import re
import sys
from pathlib import Path

from release_version import ReleaseVersionError, check_release_files


def fail(message: str) -> None:
    print(f"::error::{message}")
    raise SystemExit(1)


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def extract_release_notes(tag: str) -> str:
    text = read_text("CHANGELOG.md")
    pattern = (
        rf"^##[^\S\r\n]+{re.escape(tag)}[^\S\r\n]*$\n"
        r"(?P<body>.*?)(?=^##[^\S\r\n]+|\Z)"
    )
    match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    if not match:
        fail(f"CHANGELOG.md does not contain a section for {tag}")
    body = match.group("body").strip()
    if not body:
        fail(f"CHANGELOG.md section for {tag} is empty")
    return body


def validate_pubspec_version(tag: str) -> None:
    try:
        check_release_files(tag)
    except ReleaseVersionError as error:
        fail(str(error))


def validate_flutter_rust_bridge_lock() -> None:
    text = read_text("pubspec.lock")
    pattern = (
        r"flutter_rust_bridge:\s*\n"
        r"\s+dependency:\s+\"?direct overridden\"?\s*\n"
        r"(?:.*\n){0,8}?"
        r"\s+version:\s+\"2\.11\.1\""
    )
    if not re.search(pattern, text):
        fail("pubspec.lock must lock flutter_rust_bridge as direct overridden version 2.11.1")


def validate_windows_installer_metadata() -> None:
    expected = "UninstallDisplayName={#MyAppName}"
    for path in ("windows/build.iss", "windows/build_arm64.iss"):
        text = read_text(path)
        if expected not in text.splitlines():
            fail(f"{path} must set {expected} so Windows shows a stable app name")
        section = ""
        launch_entries = 0
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith(";"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line.lower()
                continue
            if section != "[run]" or not re.match(
                r'^Filename:\s*"\{app\}\\\{#MyAppExeName\}"\s*;', line, re.IGNORECASE
            ):
                continue
            launch_entries += 1
            flags = re.search(r"(?:^|;)\s*Flags:\s*([^;]+)", line, re.IGNORECASE)
            if flags is None or not {"nowait", "postinstall", "skipifsilent"}.issubset(
                flags.group(1).lower().split()
            ):
                fail(f"{path} must skip launching the app during silent installation")
        if launch_entries != 1:
            fail(f"{path} must contain exactly one post-install app launch entry")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME", ""))
    parser.add_argument("--write-notes")
    args = parser.parse_args()

    tag = args.tag.strip()
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-rc\.\d+)?", tag):
        fail(f"Release tag must look like v1.2.3 or v1.2.3-rc.1, got {tag!r}")

    validate_pubspec_version(tag)
    validate_flutter_rust_bridge_lock()
    validate_windows_installer_metadata()
    notes = extract_release_notes(tag)

    if args.write_notes:
        Path(args.write_notes).write_text(notes + "\n", encoding="utf-8")

    print(f"Release metadata for {tag} is valid")


if __name__ == "__main__":
    main()
