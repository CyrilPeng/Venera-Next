import json
import struct
import tempfile
import unittest
from pathlib import Path

import prepare_probe as probe


class PrepareProbeTests(unittest.TestCase):
    def test_profile_replaces_template_defaults_but_preserves_local_choices(self):
        profile = json.dumps({"targetSdkVersion": "26.0.0",
                              "compatibleSdkVersion": "5.0.5(17)",
                              "signingConfigs": [{"name": "local-developer"}]})
        configured = json.loads(probe.configure_profile(profile, "6.0.1(21)"))
        self.assertEqual(configured["compatibleSdkVersion"], "6.0.1(21)")
        self.assertEqual(configured["targetSdkVersion"], "6.0.1(21)")
        self.assertEqual(configured["signingConfigs"], [{"name": "local-developer"}])
        self.assertEqual(probe.configure_profile(json.dumps(configured), "different-sdk"),
                         json.dumps(configured))

    def test_only_one_reviewed_loader_branch_is_patched(self):
        self.assertEqual(probe.patch_qjs_loader(probe.QJS_ORIGINAL), probe.QJS_OHOS)
        for text in ("different loader", probe.QJS_ORIGINAL * 2, probe.QJS_OHOS):
            with self.assertRaises(ValueError):
                probe.patch_qjs_loader(text)

    def make_report(self, directory):
        data = bytearray(64)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH", data, 16, 3, 183)
        records = []
        for name in probe.LIBRARIES:
            path = directory / name
            path.write_bytes(data)
            records.append({"name": name, "sha256": probe.digest(path)})
        report = {"status": "cross_compile_pass", "libraries": records,
                  "target": probe.CONFIG["rust"]["target"],
                  "sdk_version": probe.CONFIG["nativeSdk"]["version"],
                  "rhttp_source_sha256": probe.source_fingerprint(),
                  "build_fingerprint": probe.build_fingerprint(),
                  "quickjs_revision": probe.CONFIG["quickjs"]["revision"],
                  "sqlite_source_sha256": probe.CONFIG["sqlite"]["amalgamationSha256"]}
        report_path = directory / "report.json"
        report_path.write_text(json.dumps(report))
        return report, report_path

    def test_complete_artifacts_match_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report, path = self.make_report(directory)
            self.assertEqual(probe.verify_native_report(path, directory), report)
            (directory / "libqjs.so").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                probe.verify_native_report(path, directory)

    def test_partial_failed_stale_or_incomplete_build_cannot_be_packaged(self):
        for key, value in (("status", "partial_compile_pass"), ("status", "failed"),
                           ("rhttp_source_sha256", "stale"),
                           ("build_fingerprint", "stale"), ("libraries", []),
                           ("sdk_version", "wrong"), ("quickjs_revision", "wrong")):
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                report, path = self.make_report(directory)
                report[key] = value
                path.write_text(json.dumps(report))
                with self.assertRaises(ValueError):
                    probe.verify_native_report(path, directory)


if __name__ == "__main__":
    unittest.main()
