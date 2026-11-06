"""Verify compiled codec exports and retained third-party notices in bundles."""

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
NOTICE = "VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
SYMBOLS = ("venera_png_encode", "venera_png_error_text", "venera_native_free",
           "venera_7z_open", "venera_7z_close", "venera_7z_count", "venera_7z_name",
           "venera_7z_kind", "venera_7z_read")


def exported_symbols(binary: Path, platform: str) -> set[str]:
    if platform == "android":
        output = subprocess.check_output(
            [os.environ.get("READELF", "readelf"), "--dyn-syms", "--wide", str(binary)], text=True
        )
        return {
            fields[7].split("@", 1)[0]
            for line in output.splitlines()
            if len(fields := line.split()) >= 8
            and fields[3] == "FUNC"
            and fields[4] in ("GLOBAL", "WEAK")
            and fields[5] in ("DEFAULT", "PROTECTED")
            and fields[6] != "UND"
        }
    output = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
    return {fields[-1].removeprefix("_")
            for line in output.splitlines() if (fields := line.split())}


def require_exports(binary: Path, platform: str):
    if platform in ("android", "macos", "ios"):
        missing = set(SYMBOLS) - exported_symbols(binary, platform)
    else:
        library = ctypes.CDLL(str(binary))
        missing = {symbol for symbol in SYMBOLS if not hasattr(library, symbol)}
    if missing:
        raise ValueError(f"{binary}: missing exported ABI {sorted(missing)}")


def verify_android(apk: Path, expected: bytes):
    with zipfile.ZipFile(apk) as archive:
        entries = set(archive.namelist())
        flutter_abis = {name.split("/")[1] for name in entries
                        if name.startswith("lib/") and name.endswith("/libflutter.so")}
        codec_abis = {name.split("/")[1] for name in entries
                      if name.startswith("lib/") and name.endswith("/libvenera_native.so")}
        if not flutter_abis or codec_abis != flutter_abis:
            raise ValueError(f"{apk}: codec ABI set {codec_abis} differs from Flutter {flutter_abis}")
        if archive.read("assets/" + NOTICE) != expected:
            raise ValueError(f"{apk}: native codec notices differ from source")
        with tempfile.TemporaryDirectory(prefix="venera-codec-bundle-") as temporary:
            binary = Path(temporary) / "libvenera_native.so"
            for abi in sorted(codec_abis):
                binary.write_bytes(archive.read(f"lib/{abi}/libvenera_native.so"))
                require_exports(binary, "android")


def verify_desktop(bundle: Path, platform: str, expected: bytes):
    if platform in ("macos", "ios"):
        apps = list(bundle.glob("*.app"))
        if len(apps) != 1:
            raise ValueError(f"{bundle}: expected exactly one built application")
        bundle = apps[0]
        binaries = {file.resolve() for file in bundle.glob("**/venera_native.framework/venera_native")}
    else:
        basename = "venera_native.dll" if platform == "windows" else "libvenera_native.so"
        binaries = {file.resolve() for file in bundle.rglob(basename)}
    if len(binaries) != 1:
        raise ValueError(f"{bundle}: expected exactly one compiled native codec library")
    binary = binaries.pop()
    if platform in ("macos", "ios"):
        architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        if "arm64" not in architectures:
            raise ValueError(f"{binary}: missing ARM64 architecture")
    require_exports(binary, platform)
    notices = {file.resolve() for file in bundle.rglob(NOTICE)}
    if not notices or any(file.read_bytes() != expected for file in notices):
        raise ValueError(f"{bundle}: native codec notices are missing or changed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("android", "windows", "linux", "macos", "ios"), required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    expected = (ROOT / "packages/venera_native/notices" / NOTICE).read_bytes()
    if args.platform == "android":
        apks = list(args.root.rglob("*.apk"))
        if not apks:
            raise ValueError(f"{args.root}: no built APKs")
        for apk in apks:
            verify_android(apk, expected)
    else:
        verify_desktop(args.root, args.platform, expected)
    print(f"Verified {args.platform} codec bundle and notices: {hashlib.sha256(expected).hexdigest()}")


if __name__ == "__main__":
    main()
