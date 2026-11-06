import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "check_native_codec_bundle.py"
SPEC = importlib.util.spec_from_file_location("native_codec_bundle", SCRIPT)
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


class NativeCodecBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="venera-codec-gate-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.notice = b"reviewed third-party notices\n"

    def apk(self, abis=("arm64-v8a",), codecs=None, notice=None):
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for abi in abis:
                archive.writestr(f"lib/{abi}/libflutter.so", b"flutter")
            for abi in abis if codecs is None else codecs:
                archive.writestr(f"lib/{abi}/libvenera_native.so", abi.encode())
            archive.writestr("assets/" + BUNDLE.NOTICE,
                             self.notice if notice is None else notice)
        return apk

    def test_android_checks_every_bundled_abi_export(self):
        checked = []
        with patch.object(BUNDLE, "require_exports",
                          side_effect=lambda binary, platform:
                          checked.append((binary.read_bytes(), platform))):
            BUNDLE.verify_android(self.apk(("arm64-v8a", "x86_64")), self.notice)
        self.assertEqual(checked, [(b"arm64-v8a", "android"), (b"x86_64", "android")])

    def test_android_rejects_missing_or_extra_codecs_and_notice_drift(self):
        for codecs in ((), ("arm64-v8a", "x86_64")):
            with self.assertRaisesRegex(ValueError, "codec ABI set"):
                BUNDLE.verify_android(self.apk(codecs=codecs), self.notice)
        with self.assertRaisesRegex(ValueError, "notices differ"):
            BUNDLE.verify_android(self.apk(notice=b"changed"), self.notice)

    def test_export_check_rejects_imported_private_and_similarly_named_symbols(self):
        rows = [f"{i}: 00 4 FUNC GLOBAL DEFAULT 1 {symbol}"
                for i, symbol in enumerate(BUNDLE.SYMBOLS[:-1])]
        rows += ["20: 00 4 FUNC GLOBAL DEFAULT UND venera_7z_read",
                 "21: 00 4 FUNC LOCAL HIDDEN 1 venera_7z_read",
                 "22: 00 4 FUNC GLOBAL DEFAULT 1 venera_7z_read_more"]
        with patch.object(BUNDLE.subprocess, "check_output", return_value="\n".join(rows)):
            with self.assertRaisesRegex(ValueError, "venera_7z_read"):
                BUNDLE.require_exports(self.root / "codec.so", "android")
        with patch.object(BUNDLE.subprocess, "check_output",
                          return_value="\n".join("00 T _" + symbol for symbol in
                                                 (*BUNDLE.SYMBOLS[:-1], "venera_7z_read_more"))):
            with self.assertRaisesRegex(ValueError, "venera_7z_read"):
                BUNDLE.require_exports(self.root / "codec", "macos")

    def apple(self):
        app = self.root / "VeneraNext.app"
        framework = app / "Frameworks/venera_native.framework"
        framework.mkdir(parents=True)
        (framework / "venera_native").write_bytes(b"built library")
        (framework / BUNDLE.NOTICE).write_bytes(self.notice)
        return framework

    def test_apple_requires_arm64_and_notice_inside_built_application(self):
        framework = self.apple()
        with patch.object(BUNDLE, "require_exports"), patch.object(
                BUNDLE.subprocess, "check_output", return_value="x86_64\n"):
            with self.assertRaisesRegex(ValueError, "ARM64"):
                BUNDLE.verify_desktop(self.root, "macos", self.notice)
        with patch.object(BUNDLE, "require_exports"), patch.object(
                BUNDLE.subprocess, "check_output", return_value="arm64\n"):
            BUNDLE.verify_desktop(self.root, "ios", self.notice)
            (framework / BUNDLE.NOTICE).unlink()
            (self.root / BUNDLE.NOTICE).write_bytes(self.notice)
            with self.assertRaisesRegex(ValueError, "notices are missing"):
                BUNDLE.verify_desktop(self.root, "ios", self.notice)

    def test_desktop_rejects_multiple_libraries_and_changed_notice(self):
        (self.root / "venera_native.dll").write_bytes(b"library")
        (self.root / BUNDLE.NOTICE).write_bytes(b"changed")
        with patch.object(BUNDLE, "require_exports"):
            with self.assertRaisesRegex(ValueError, "notices are missing or changed"):
                BUNDLE.verify_desktop(self.root, "windows", self.notice)
        nested = self.root / "stale"
        nested.mkdir()
        (nested / "venera_native.dll").write_bytes(b"stale library")
        with self.assertRaisesRegex(ValueError, "exactly one compiled"):
            BUNDLE.verify_desktop(self.root, "windows", self.notice)


if __name__ == "__main__":
    unittest.main()
