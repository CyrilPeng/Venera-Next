"""Describe and audit a paired unsigned lab build, never user signing material."""

import hashlib
import json
import re
from pathlib import Path


BUNDLE_NAME = "com.github.cyrilpeng.harmonyos_probe"
STAGES = {
    "baseline": {"version_name": "0.2.0", "version_code": 2},
    "upgrade": {"version_name": "0.2.1", "version_code": 3},
}
ASSET = "resources/rawfile/flutter_assets/assets/sideload-build.json"


def probe_fingerprint():
    root = Path(__file__).parent
    files = [root / "prepare_probe.py", Path(__file__)]
    files.extend(sorted((root / "probe").rglob("*.template")))
    result = hashlib.sha256()
    for path in files:
        result.update(path.relative_to(root).as_posix().encode() + b"\0")
        result.update(path.read_bytes())
    return result.hexdigest()


def build_metadata(stage, commit, native_report):
    if stage not in STAGES or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a known sideload stage and full source commit")
    identity = {
        "source_commit": commit,
        "probe_source_sha256": probe_fingerprint(),
        "native_build_fingerprint": native_report["build_fingerprint"],
        "native_libraries": {item["name"]: item["sha256"]
                             for item in native_report["libraries"]},
    }
    pair_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return {
        "schema": 1, "purpose": "xiaobai_sideload_lab", "branch": "HarmonyOS",
        "bundle_name": BUNDLE_NAME, "stage": stage, **STAGES[stage],
        "pair_id": pair_id, "source_commit": commit,
        "probe_source_sha256": identity["probe_source_sha256"],
        "minimum_sdk": "26.0.0", "reader_integrated": False,
    }


def audit_metadata(archive, expected):
    metadata = json.loads(archive.read(ASSET))
    if metadata != expected:
        raise ValueError("Packaged sideload metadata differs from the prepared build")
    app = json.loads(archive.read("module.json"))["app"]
    for packed, declared in (("bundleName", "bundle_name"), ("versionName", "version_name"),
                             ("versionCode", "version_code")):
        if app.get(packed) != metadata[declared]:
            raise ValueError(f"Actual HAP metadata differs: {packed}")
    # The current lab uses API 26 for both compilation and minimum runtime.
    if app.get("minAPIVersion") != 260000026 or app.get("targetAPIVersion") != 260000026:
        raise ValueError("Unexpected actual HAP minimum/target API; review compatibility first")
    return {"bundle_name": app["bundleName"], "version_name": app["versionName"],
            "version_code": app["versionCode"], "minimum_api": app["minAPIVersion"],
            "target_api": app["targetAPIVersion"]}


def pair_manifest(reports):
    if len(reports) != 2:
        raise ValueError("Exactly two successfully audited HAPs are required")
    baseline, upgrade = reports
    for report, stage in zip(reports, STAGES):
        metadata = report.get("sideload_build", {})
        if (report.get("status") != "packaging_pass" or report.get("signed") is not False
                or report.get("runtime_verified") is not False
                or report.get("reader_integrated") is not False
                or metadata.get("schema") != 1
                or metadata.get("purpose") != "xiaobai_sideload_lab"
                or metadata.get("stage") != stage or metadata.get("bundle_name") != BUNDLE_NAME
                or any(metadata.get(key) != value for key, value in STAGES[stage].items())):
            raise ValueError("Incomplete, signed or mismatched sideload build")
        if not re.fullmatch(r"[0-9a-f]{64}", metadata.get("pair_id", "")):
            raise ValueError("Missing sideload pair identity")
        packaged = report.get("packaged_app", {})
        if any(packaged.get(key) != metadata[key]
               for key in ("bundle_name", "version_name", "version_code")):
            raise ValueError("HAP metadata audit is missing")
        if packaged.get("minimum_api") != 260000026 or packaged.get("target_api") != 260000026:
            raise ValueError("HAP API audit is missing")
        if (not re.fullmatch(r"[0-9a-f]{64}", report.get("sha256", ""))
                or type(report.get("bytes")) is not int or report["bytes"] <= 0):
            raise ValueError("Missing original HAP digest or size")
    first, second = baseline["sideload_build"], upgrade["sideload_build"]
    common = ("pair_id", "source_commit", "probe_source_sha256", "minimum_sdk", "bundle_name")
    if any(first[key] != second[key] for key in common):
        raise ValueError("The HAPs were not built from the same probe/native baseline")
    return {
        "schema": 1, "purpose": "xiaobai_sideload_lab", "pair_id": first["pair_id"],
        "source_commit": first["source_commit"], "bundle_name": BUNDLE_NAME,
        "minimum_sdk": first["minimum_sdk"], "signed": False,
        "runtime_verified": False, "reader_integrated": False,
        "artifacts": [{"name": report["hap"], "bytes": report["bytes"],
                       "sha256": report["sha256"], "build": report["sideload_build"],
                       "packaged_app": report["packaged_app"]} for report in reports],
    }
