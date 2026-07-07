import argparse
import hashlib
import re
from datetime import date
from pathlib import Path

from release_version import load_release_config


PACKAGE_IDENTIFIER = "CyrilPeng.VeneraNext"
PACKAGE_PUBLISHER = "CyrilPeng/venera-next"
PACKAGE_NAME = "VeneraNext"
PACKAGE_MONIKER = "venera-next"
MANIFEST_VERSION = "1.10.0"
SCHEMA_BASE_URL = "https://aka.ms"
SCHEMA_HEADERS = {
    "version": (
        f"# yaml-language-server: $schema="
        f"{SCHEMA_BASE_URL}/winget-manifest.version.{MANIFEST_VERSION}.schema.json"
    ),
    "installer": (
        f"# yaml-language-server: $schema="
        f"{SCHEMA_BASE_URL}/winget-manifest.installer.{MANIFEST_VERSION}.schema.json"
    ),
    "defaultLocale": (
        f"# yaml-language-server: $schema="
        f"{SCHEMA_BASE_URL}/winget-manifest.defaultLocale.{MANIFEST_VERSION}.schema.json"
    ),
}
APP_ID = "{C6B7E69A-0FD6-4F2A-AC64-7D1AE8A40FB8}_is1"
REPOSITORY_URL = "https://github.com/CyrilPeng/venera-next"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-rc\.\d+)?$")


class WingetManifestError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise WingetManifestError(message)


def package_version(version: str | None) -> str:
    if version is not None:
        result = version.strip().removeprefix("v")
    else:
        result = load_release_config()["version"]
    if not VERSION_RE.fullmatch(result):
        fail(f"version must look like 1.2.3 or 1.2.3-rc.1, got {result!r}")
    return result


def installer_url(version: str) -> str:
    return (
        f"{REPOSITORY_URL}/releases/download/v{version}/"
        f"{PACKAGE_NAME}-{version}-windows-installer.exe"
    )


def installer_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def expected_installer_name(version: str) -> str:
    return f"{PACKAGE_NAME}-{version}-windows-installer.exe"


def validate_installer_path(version: str, path: Path) -> None:
    if not path.is_file():
        fail(f"installer does not exist: {path}")
    expected_name = expected_installer_name(version)
    if path.name != expected_name:
        fail(f"installer must be named {expected_name}, got {path.name}")


def manifest_dir(output: Path, version: str) -> Path:
    return output / "manifests" / "c" / "CyrilPeng" / "VeneraNext" / version


def clean_output(path: Path) -> None:
    if not path.exists():
        return
    for child in path.iterdir():
        if child.is_dir():
            clean_output(child)
            child.rmdir()
        else:
            child.unlink()


def version_manifest(version: str) -> str:
    return f"""{SCHEMA_HEADERS["version"]}
PackageIdentifier: {PACKAGE_IDENTIFIER}
PackageVersion: {version}
DefaultLocale: en-US
ManifestType: version
ManifestVersion: {MANIFEST_VERSION}
"""


def installer_manifest(
    version: str,
    sha256: str,
    url: str,
    release_date: str | None,
) -> str:
    release_date_block = f"    ReleaseDate: {release_date}\n" if release_date else ""
    return f"""{SCHEMA_HEADERS["installer"]}
PackageIdentifier: {PACKAGE_IDENTIFIER}
PackageVersion: {version}
InstallerType: inno
Scope: machine
UpgradeBehavior: install
InstallModes:
- interactive
- silent
- silentWithProgress
InstallerSwitches:
  Silent: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  SilentWithProgress: /SILENT /SUPPRESSMSGBOXES /NORESTART
  Custom: /NORESTART
AppsAndFeaturesEntries:
- DisplayName: {PACKAGE_NAME}
  Publisher: {PACKAGE_PUBLISHER}
  ProductCode: "{APP_ID}"
  InstallerType: inno
Installers:
  - Architecture: x64
    InstallerUrl: {url}
    InstallerSha256: {sha256}
    ProductCode: "{APP_ID}"
{release_date_block}ManifestType: installer
ManifestVersion: {MANIFEST_VERSION}
"""


def locale_manifest(version: str) -> str:
    return f"""{SCHEMA_HEADERS["defaultLocale"]}
PackageIdentifier: {PACKAGE_IDENTIFIER}
PackageVersion: {version}
PackageLocale: en-US
Publisher: {PACKAGE_PUBLISHER}
PublisherUrl: {REPOSITORY_URL}
PublisherSupportUrl: {REPOSITORY_URL}/issues
Author: CyrilPeng
PackageName: {PACKAGE_NAME}
PackageUrl: {REPOSITORY_URL}
License: GPL-3.0
LicenseUrl: {REPOSITORY_URL}/blob/main/LICENSE
Copyright: Copyright (C) CyrilPeng
ShortDescription: A comic app.
Description: VeneraNext is a free and open-source app for comic reading.
Moniker: {PACKAGE_MONIKER}
Tags:
- comic
- manga
- reader
ReleaseNotesUrl: {REPOSITORY_URL}/releases/tag/v{version}
ManifestType: defaultLocale
ManifestVersion: {MANIFEST_VERSION}
"""


def write_manifest_files(
    output: Path,
    version: str,
    sha256: str,
    url: str,
    release_date: str | None,
    clean: bool,
) -> Path:
    destination = manifest_dir(output, version)
    if clean:
        clean_output(destination)
    destination.mkdir(parents=True, exist_ok=True)
    files = {
        f"{PACKAGE_IDENTIFIER}.yaml": version_manifest(version),
        f"{PACKAGE_IDENTIFIER}.installer.yaml": installer_manifest(
            version,
            sha256,
            url,
            release_date,
        ),
        f"{PACKAGE_IDENTIFIER}.locale.en-US.yaml": locale_manifest(version),
    }
    for name, content in files.items():
        (destination / name).write_text(content, encoding="utf-8", newline="\n")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", help="release version, for example 1.10.2")
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--installer-url")
    parser.add_argument("--output", type=Path, default=Path("build/winget"))
    parser.add_argument("--release-date", default=date.today().isoformat())
    parser.add_argument("--allow-prerelease", action="store_true")
    parser.add_argument("--no-clean", action="store_true")
    parser.add_argument("--print-path", action="store_true")
    args = parser.parse_args()

    try:
        version = package_version(args.version)
        if "-" in version and not args.allow_prerelease:
            fail("winget manifest generation is limited to stable releases by default")
        validate_installer_path(version, args.installer)
        destination = write_manifest_files(
            args.output,
            version,
            installer_sha256(args.installer),
            args.installer_url or installer_url(version),
            args.release_date,
            clean=not args.no_clean,
        )
        if args.print_path:
            print(destination.as_posix())
    except WingetManifestError as error:
        print(f"::error::{error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
