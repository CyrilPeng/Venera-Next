import hashlib
import copy
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import ci_build
import ci_sdk
from native_build import CONFIG


class CiSdkTests(unittest.TestCase):
    def test_archive_requires_both_size_and_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "sdk.zip.001"
            path.write_bytes(b"sdk-archive")
            asset = {"name": path.name, "bytes": path.stat().st_size,
                     "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            ci_sdk.verify_archive(path, asset)
            for update in ({"bytes": 0}, {"sha256": "0" * 64}, {"sha256": None}):
                with self.assertRaises(ValueError):
                    ci_sdk.verify_archive(path, asset | update)

    def test_public_and_ci_sdks_cannot_be_confused(self):
        config = copy.deepcopy(CONFIG)
        for asset in config["harmonyCiSdk"]["archives"]:
            asset["sha256"] = asset["sha256"] or "1" * 64
        public = {"apiVersion": "20", "version": CONFIG["nativeSdk"]["version"]}
        ci_sdk.check_native_sdk(public, "public", CONFIG)
        with self.assertRaises(ValueError):
            ci_sdk.check_native_sdk(public | {"apiVersion": "21"}, "public", CONFIG)
        metadata = {"apiVersion": str(CONFIG["harmonyCiSdk"]["api"]),
                    "version": CONFIG["harmonyCiSdk"].get("nativeVersion", "observed-component")}
        receipt = {"status": "verified", "native": metadata,
                   "archives": ci_sdk.archive_records(config)}
        ci_sdk.check_native_sdk(metadata, "harmony-ci", config, receipt)
        for broken in (None, receipt | {"status": "failed"}, receipt | {"archives": []},
                       receipt | {"native": metadata | {"version": "other"}}):
            with self.assertRaises(ValueError):
                ci_sdk.check_native_sdk(metadata, "harmony-ci", config, broken)
        with self.assertRaises(ValueError):
            ci_sdk.check_native_sdk(public, "harmony-ci", config, receipt)
        with self.assertRaises(ValueError):
            ci_sdk.check_native_sdk(metadata, "unknown-profile", config, receipt)
        config["harmonyCiSdk"]["archives"][0]["sha256"] = None
        with self.assertRaises(ValueError):
            ci_sdk.check_native_sdk(metadata, "harmony-ci", config, receipt)


class HapAuditTests(unittest.TestCase):
    def make_hap(self, path, *, missing=None, changed=None):
        data = bytearray(64)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH", data, 16, 3, 183)
        names = {"libflutter.so", "libapp.so", *ci_build.LIBRARIES}
        expected = {name: hashlib.sha256(data).hexdigest() for name in ci_build.LIBRARIES}
        with zipfile.ZipFile(path, "w") as archive:
            for name in names - {missing}:
                archive.writestr(f"libs/arm64-v8a/{name}", data + (b"changed" if name == changed else b""))
        return expected

    def test_audits_packaged_arm64_libraries_and_exact_native_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "entry-unsigned.hap"
            expected = self.make_hap(path)
            self.assertEqual(len(ci_build.audit_hap(path, expected)), 6)
            with self.assertRaises(ValueError):
                ci_build.audit_hap(path, {})
            self.make_hap(path, changed="libqjs.so")
            with self.assertRaises(ValueError):
                ci_build.audit_hap(path, expected)

    def test_rejects_empty_missing_or_mislabeled_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "entry-unsigned.hap"
            for missing in ("libapp.so", "librhttp.so", "libc++_shared.so"):
                expected = self.make_hap(path, missing=missing)
                with self.assertRaises(ValueError):
                    ci_build.audit_hap(path, expected)
            with zipfile.ZipFile(path, "w"):
                pass
            with self.assertRaises(ValueError):
                ci_build.audit_hap(path)
            with self.assertRaises(ValueError):
                ci_build.audit_hap(path.with_name("entry-signed.hap"))


if __name__ == "__main__":
    unittest.main()
