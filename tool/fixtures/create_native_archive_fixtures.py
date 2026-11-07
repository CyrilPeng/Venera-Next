"""Independent 7z fixtures: official CLI for compression; specified Copy headers
for hostile filenames and link attributes. Never extract the hostile fixtures.
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "packages/venera_native/test/fixtures"


def number(value):
    for count in range(8):
        if value < 1 << (7 + 7 * count):
            prefix = ((0xFF << (8 - count)) & 0xFF) if count else 0
            return bytes([prefix | (value >> (8 * count))]) + value.to_bytes(8, "little")[:count]
    return b"\xff" + value.to_bytes(8, "little")


def copy_archive(entries, *, include_names=True):
    """Create a simple uncompressed 7z according to DOC/7zFormat.txt.

    Each input entry is (name, bytes, Win/Unix attributes). This independent
    writer lets tests exercise names a command-line archiver may normalize.
    """
    payload = b"".join(data for _, data, _ in entries)
    header = bytearray(b"\x01\x04\x06")  # Header/MainStreamsInfo/PackInfo.
    header += number(0) + number(len(entries)) + b"\x09"
    for _, data, _ in entries:
        header += number(len(data))
    header += b"\x0a\x01" + b"".join(struct.pack("<I", zlib.crc32(data)) for _, data, _ in entries)
    header += b"\x00\x07\x0b" + number(len(entries)) + b"\x00"
    header += b"\x01\x01\x00" * len(entries)  # One Copy coder per folder.
    header += b"\x0c" + b"".join(number(len(data)) for _, data, _ in entries)
    header += b"\x0a\x01" + b"".join(struct.pack("<I", zlib.crc32(data)) for _, data, _ in entries)
    header += b"\x00\x08\x00\x00\x05" + number(len(entries))
    if include_names:
        names = b"\x00" + b"".join((name + "\0").encode("utf-16-le") for name, _, _ in entries)
        header += b"\x11" + number(len(names)) + names
    attributes = b"\x01\x00" + b"".join(struct.pack("<I", attr) for _, _, attr in entries)
    header += b"\x15" + number(len(attributes)) + attributes + b"\x00\x00"
    start = struct.pack("<QQI", len(payload), len(header), zlib.crc32(header))
    return b"7z\xbc\xaf'\x1c\x00\x04" + struct.pack("<I", zlib.crc32(start)) + start + payload + header


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seven-zip", required=True, help="Official 7z/7zr executable")
    args = parser.parse_args()
    DESTINATION.mkdir(parents=True, exist_ok=True)
    expected = {
        "book/章节一/第一页.rgba": bytes([255, 0, 0, 255, 0, 20, 255, 128]),
        "book/第二章/🌈.bin": bytes(range(256)),
        "book/empty.bin": b"",
        **{f"book/pages/{index:02}.bin": bytes([index]) * (index * 37 + 1) for index in range(1, 13)},
    }
    with tempfile.TemporaryDirectory(prefix="venera-native-fixtures-") as directory:
        workspace = Path(directory)
        for name, content in expected.items():
            file = workspace / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content)
        for name, flags in (("solid", ["-ms=on"]), ("non-solid", ["-ms=off"]),
                            ("encrypted", ["-pfixture-password", "-mhe=on"])):
            target = DESTINATION / (name + ".7z")
            # Rewrite only the explicitly named fixture files in this project.
            if target.exists():
                target.unlink()
            subprocess.run([args.seven_zip, "a", "-t7z", "-mx=5", *flags,
                            str(target), "book"], cwd=workspace, check=True, capture_output=True)
    expected_hex = {name: data.hex() for name, data in expected.items()}
    (DESTINATION / "expected.json").write_text(json.dumps(expected_hex, ensure_ascii=False, indent=2) + "\n",
                                              encoding="utf-8")
    unsafe = {
        "traversal": [("../escape.bin", b"escape", 0x20)],
        "absolute": [("/escape.bin", b"escape", 0x20)],
        "drive": [("C:/escape.bin", b"escape", 0x20)],
        "duplicate": [("safe/page.bin", b"a", 0x20), ("safe/./page.bin", b"b", 0x20)],
        "file-parent": [("safe", b"a", 0x20), ("safe/page.bin", b"b", 0x20)],
        "symlink": [("safe/link", b"../escape.bin", (0o120777 << 16) | 0x8020)],
        "copy": [("safe/page.bin", b"verified-data", 0x20)],
    }
    for name, entries in unsafe.items():
        (DESTINATION / (name + ".7z")).write_bytes(copy_archive(entries))
    (DESTINATION / "missing-name.7z").write_bytes(
        copy_archive(unsafe["copy"], include_names=False))
    damaged = bytearray(copy_archive(unsafe["copy"]))
    damaged[32] ^= 0x40  # Payload mutation; header remains valid and expects original CRC.
    (DESTINATION / "bad-crc.7z").write_bytes(damaged)
    (DESTINATION / "truncated.7z").write_bytes(copy_archive(unsafe["copy"])[:-7])
    print(f"Created independent fixtures in {DESTINATION}")


if __name__ == "__main__":
    main()
