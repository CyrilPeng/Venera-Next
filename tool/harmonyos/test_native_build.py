import importlib.util
import shlex
import struct
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "native_build", Path(__file__).with_name("native_build.py")
)
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)


class NativeBuildTests(unittest.TestCase):
    def test_output_stays_in_experiment_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(NATIVE.require_within(root / "native", root), root / "native")
            for candidate in (root, root / "../elsewhere"):
                with self.assertRaises(ValueError):
                    NATIVE.require_within(candidate, root)

    def test_rejects_host_or_non_elf_libraries(self):
        for data in (b"MZ" + bytes(100), b"", b"\x7fELF" + bytes(100)):
            with self.assertRaises(ValueError):
                NATIVE.validate_elf(data)
        data = bytearray(64)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH", data, 16, 3, 62)
        with self.assertRaises(ValueError):
            NATIVE.validate_elf(data)
        struct.pack_into("<HH", data, 16, 3, 183)
        NATIVE.validate_elf(data)

    def test_pins_match_current_application(self):
        root = NATIVE.ROOT
        lock = (root / "pubspec.lock").read_text(encoding="utf-8")
        self.assertIn(NATIVE.CONFIG["quickjs"]["revision"], lock)
        self.assertIn('version = "=2.11.1"',
                      (root / "packages/rhttp/rust/Cargo.toml").read_text())
        self.assertEqual(NATIVE.CONFIG["rust"]["version"], "1.92.0")
        self.assertIn('channel = "1.92.0"', (root / "rust-toolchain.toml").read_text())

    def test_sqlite_features_include_existing_storage_contracts(self):
        for feature in ("SQLITE_ENABLE_FTS5", "SQLITE_ENABLE_RTREE",
                        "SQLITE_ENABLE_SESSION", "SQLITE_ENABLE_PREUPDATE_HOOK"):
            self.assertIn(feature, NATIVE.SQLITE_DEFINES)
        self.assertNotIn("SQLITE_HAVE_LOCALTIME_S", NATIVE.SQLITE_DEFINES)

    def test_rust_fingerprint_is_content_addressed(self):
        self.assertRegex(NATIVE.source_fingerprint(), r"^[a-f0-9]{64}$")

    def test_target_cflags_preserve_sdk_paths_with_spaces(self):
        native = Path("D:/SDK with spaces/native")
        self.assertEqual(shlex.split(NATIVE.target_cflags(native)), [
            "--target=aarch64-linux-ohos",
            "--sysroot=D:/SDK with spaces/native/sysroot", "-D__MUSL__",
        ])


if __name__ == "__main__":
    unittest.main()
