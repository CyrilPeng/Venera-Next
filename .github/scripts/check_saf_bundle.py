"""Verify the complete Android SAF ABI and project notice in every APK."""

import argparse
from pathlib import Path
import tempfile
import zipfile

from check_native_codec_bundle import exported_symbols


ROOT = Path(__file__).resolve().parents[2]
NOTICE = "VENERA_SAF_NOTICES.txt"
SYMBOLS = {
    "venera_saf_metadata", "venera_saf_open", "venera_saf_retain",
    "venera_saf_descriptor", "venera_saf_release", "venera_saf_close_payload",
    "venera_saf_read", "venera_saf_write", "venera_saf_value",
    "venera_saf_descriptor_count", "venera_saf_free", "JNI_OnLoad",
    "Java_com_cyrilpeng_venera_1saf_NativeBridge_initialize",
}


def verify(apk: Path, expected: bytes):
    with zipfile.ZipFile(apk) as archive:
        entries = set(archive.namelist())
        flutter = {name.split("/")[1] for name in entries
                   if name.startswith("lib/") and name.endswith("/libflutter.so")}
        saf = {name.split("/")[1] for name in entries
               if name.startswith("lib/") and name.endswith("/libvenera_saf.so")}
        if not flutter or saf != flutter:
            raise ValueError(f"{apk}: SAF ABI set {saf} differs from Flutter {flutter}")
        if archive.read("assets/" + NOTICE) != expected:
            raise ValueError(f"{apk}: SAF notice differs from reviewed source")
        with tempfile.TemporaryDirectory(prefix="venera-saf-bundle-") as temporary:
            binary = Path(temporary) / "libvenera_saf.so"
            for abi in sorted(saf):
                binary.write_bytes(archive.read(f"lib/{abi}/libvenera_saf.so"))
                missing = SYMBOLS - exported_symbols(binary, "android")
                if missing: raise ValueError(f"{apk}/{abi}: missing SAF exports {sorted(missing)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    apks = list(args.root.rglob("*.apk"))
    if not apks: raise ValueError(f"{args.root}: no built APKs")
    expected = (ROOT / "packages/venera_saf/notices" / NOTICE).read_bytes()
    for apk in apks: verify(apk, expected)
    print(f"Verified SAF ABI and retained notice in {len(apks)} APKs")


if __name__ == "__main__": main()
