import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "check_saf_bundle.py"
SPEC = importlib.util.spec_from_file_location("saf_bundle", SCRIPT)
SAF = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPT.parent))
try: SPEC.loader.exec_module(SAF)
finally: sys.path.pop(0)


class SafBundleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="venera-saf-abi-gate-")
        self.addCleanup(directory.cleanup)
        self.apk = Path(directory.name) / "app.apk"
        self.notice = b"project GPL notice\n"

    def bundle(self, saf=("arm64-v8a", "x86_64"), notice=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi in ("arm64-v8a", "x86_64"):
                archive.writestr(f"lib/{abi}/libflutter.so", b"flutter")
            for abi in saf:
                archive.writestr(f"lib/{abi}/libvenera_saf.so", abi.encode())
            archive.writestr("assets/" + SAF.NOTICE, self.notice if notice is None else notice)

    def test_requires_exact_abi_set_and_reviewed_notice(self):
        for abis in (("arm64-v8a",), ("arm64-v8a", "x86_64", "armeabi-v7a")):
            self.bundle(abis)
            with self.assertRaisesRegex(ValueError, "SAF ABI set"):
                SAF.verify(self.apk, self.notice)
        self.bundle(notice=b"changed")
        with self.assertRaisesRegex(ValueError, "notice differs"):
            SAF.verify(self.apk, self.notice)

    def test_checks_data_and_jni_exports_for_every_abi(self):
        self.bundle()
        checked = []
        def exports(binary, platform):
            checked.append((binary.read_bytes(), platform))
            return SAF.SYMBOLS
        with patch.object(SAF, "exported_symbols", side_effect=exports):
            SAF.verify(self.apk, self.notice)
        self.assertEqual(checked, [(b"arm64-v8a", "android"), (b"x86_64", "android")])
        for missing in ("venera_saf_close_payload", "venera_saf_value",
                        "Java_com_cyrilpeng_venera_1saf_NativeBridge_initialize"):
            with patch.object(SAF, "exported_symbols", return_value=SAF.SYMBOLS - {missing}):
                with self.assertRaisesRegex(ValueError, missing):
                    SAF.verify(self.apk, self.notice)


if __name__ == "__main__": unittest.main()
