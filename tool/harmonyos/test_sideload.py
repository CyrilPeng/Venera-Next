import copy
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import review_sideload
import sideload


def metadata(stage):
    return sideload.build_metadata(stage, "a" * 40, {
        "build_fingerprint": "native-source-fingerprint",
        "libraries": [{"name": "libqjs.so", "sha256": "b" * 64}],
    })


def build_report(stage):
    build = metadata(stage)
    return {"status": "packaging_pass", "signed": False, "runtime_verified": False,
            "reader_integrated": False,
            "sideload_build": build, "hap": f"probe-{stage}-unsigned.hap",
            "bytes": 123, "sha256": "c" * 64,
            "packaged_app": {"bundle_name": sideload.BUNDLE_NAME,
                             "version_name": build["version_name"],
                             "version_code": build["version_code"],
                             "device_types": list(sideload.DEVICE_TYPES),
                             "minimum_api": 260000026, "target_api": 260000026}}


def device_reports(manifest):
    reports = []
    for index, stage in enumerate(("baseline", "baseline", "upgrade")):
        status = "core_checks_pass" if index else "core_pass_restart_pending"
        report = {
            "probe_schema": 2, "runtime_platform": "ohos", "status": status,
            "launch_id": f"launch-{index}", "sideload_build": metadata(stage),
            "sideload_state": {
                "status": "upgrade_data_present" if index == 2 else "baseline_ready",
                "marker": "d" * 32, "pair_id": manifest["pair_id"],
                "baseline_version_code": sideload.STAGES["baseline"]["version_code"],
                "first_launch_id": "launch-0",
                "earlier_launch": bool(index),
            },
            "events": [{"type": "result", "id": name, "status": "pass"}
                       for name in ("quickjs", "rhttp", "sqlite")]
                      + [{"type": "result", "id": "process_restart",
                          "status": "pass" if index else "pending"},
                         {"type": "done", "status": status}],
        }
        reports.append(report)
    return reports


class SideloadBuildTests(unittest.TestCase):
    def test_pair_has_same_identity_and_increasing_versions(self):
        first, second = metadata("baseline"), metadata("upgrade")
        self.assertEqual(first["pair_id"], second["pair_id"])
        self.assertEqual(first["bundle_name"], second["bundle_name"])
        self.assertLess(first["version_code"], second["version_code"])
        self.assertNotEqual(first["version_name"], second["version_name"])
        for stage, commit in (("unknown", "a" * 40), ("baseline", "main")):
            with self.assertRaises(ValueError):
                sideload.build_metadata(stage, commit, {})

    def test_audit_checks_actual_manifest_not_only_filename_or_asset(self):
        expected = metadata("baseline")
        app = {"bundleName": sideload.BUNDLE_NAME, "versionName": expected["version_name"],
               "versionCode": expected["version_code"],
               "minAPIVersion": 260000026, "targetAPIVersion": 260000026}
        for update in ({}, {"bundleName": "another.app"}, {"versionCode": 1},
                       {"versionName": "wrong"}, {"minAPIVersion": 6000020},
                       {"targetAPIVersion": 6000020}):
            with self.subTest(update=update), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "probe-unsigned.hap"
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(sideload.ASSET, json.dumps(expected))
                    archive.writestr("module.json", json.dumps({"app": app | update,
                        "module": {"deviceTypes": list(sideload.DEVICE_TYPES)}}))
                with zipfile.ZipFile(path) as archive:
                    if update:
                        with self.assertRaises(ValueError):
                            sideload.audit_metadata(archive, expected)
                    else:
                        self.assertEqual(sideload.audit_metadata(archive, expected)["version_code"],
                                         sideload.STAGES["baseline"]["version_code"])
                        with self.assertRaises(ValueError):
                            sideload.audit_metadata(archive, metadata("upgrade"))

    def test_actual_hap_device_types_cannot_be_missing_phone_only_or_broadened(self):
        for devices in (None, [], ["phone"], ["tablet"], ["phone", "tablet", "2in1"],
                        ["phone", "tablet", "tablet"], "tablet"):
            with self.subTest(devices=devices), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "probe-unsigned.hap"
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("module.json", json.dumps({"module": {"deviceTypes": devices}}))
                with zipfile.ZipFile(path) as archive, self.assertRaises(ValueError):
                    sideload.audit_device_types(archive)

    def test_pair_rejects_incomplete_failed_signed_or_mixed_builds(self):
        reports = [build_report(stage) for stage in sideload.STAGES]
        manifest = sideload.pair_manifest(reports)
        self.assertFalse(manifest["runtime_verified"])
        self.assertFalse(manifest["reader_integrated"])
        with self.assertRaises(ValueError):
            sideload.pair_manifest(reports[:1])
        for key, value in (("status", "failed"), ("signed", True), ("runtime_verified", True)):
            broken = copy.deepcopy(reports)
            broken[1][key] = value
            with self.assertRaises(ValueError):
                sideload.pair_manifest(broken)
        for key, value in (("pair_id", "e" * 64), ("source_commit", "f" * 40),
                           ("stage", "baseline"), ("version_code", 2),
                           ("bundle_name", "another.app"), ("device_types", ["phone"]),
                           ("baseline_version_code", 2)):
            broken = copy.deepcopy(reports)
            broken[1]["sideload_build"][key] = value
            with self.assertRaises(ValueError):
                sideload.pair_manifest(broken)
        broken = copy.deepcopy(reports)
        broken[1]["packaged_app"]["device_types"] = ["phone"]
        with self.assertRaises(ValueError):
            sideload.pair_manifest(broken)


class SideloadReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest = sideload.pair_manifest([build_report(stage) for stage in sideload.STAGES])
        self.reports = device_reports(self.manifest)

    def test_matching_reports_only_verify_reported_checks_not_signing_or_reader(self):
        result = review_sideload.review(self.manifest, self.reports)
        self.assertEqual(result["status"], "reported_checks_pass")
        for key in ("signing_identity_verified", "certificate_renewal_verified", "reader_integrated"):
            self.assertFalse(result[key])

    def test_host_wrong_build_missing_baseline_or_recreated_data_cannot_pass(self):
        mutations = [
            lambda r: r[2].update(runtime_platform="windows"),
            lambda r: r[2].update(probe_schema=1),
            lambda r: r[2].update(status="failed"),
            lambda r: r[2].update(launch_id=r[1]["launch_id"]),
            lambda r: r[2]["sideload_build"].update(pair_id="e" * 64),
            lambda r: r[2]["sideload_state"].update(status="missing_baseline"),
            lambda r: r[2]["sideload_state"].update(marker="e" * 32),
            lambda r: r[2]["sideload_state"].update(earlier_launch=False),
            lambda r: r[0]["sideload_state"].update(first_launch_id="lost-first-report"),
            lambda r: r[1]["events"][0].update(status="fail"),
            lambda r: r[1]["events"].pop(),
            lambda r: r[1]["events"][-2].update(status="pending"),
            lambda r: r[2]["events"].append({"type": "fatal"}),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                reports = copy.deepcopy(self.reports)
                mutate(reports)
                with self.assertRaises(ValueError):
                    review_sideload.review(self.manifest, reports)

    def test_missing_report_or_unknown_manifest_cannot_pass(self):
        with self.assertRaises(ValueError):
            review_sideload.review(self.manifest, self.reports[:2])
        with self.assertRaises(ValueError):
            review_sideload.review(self.manifest | {"runtime_verified": True}, self.reports)
        with self.assertRaises(ValueError):
            review_sideload.review(self.manifest | {"device_types": ["phone"]}, self.reports)


if __name__ == "__main__":
    unittest.main()
