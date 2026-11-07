"""Review user-exported synthetic probe reports; never sign or install a HAP."""

import argparse
import json
import re
from pathlib import Path

from sideload import BUNDLE_NAME, DEVICE_TYPES, STAGES


def require(condition, message):
    if not condition:
        raise ValueError(message)


def review(manifest, reports):
    require(manifest.get("schema") == 1 and manifest.get("purpose") == "xiaobai_sideload_lab",
            "Unknown sideload manifest")
    require(manifest.get("signed") is False and manifest.get("runtime_verified") is False
            and manifest.get("reader_integrated") is False, "Unexpected manifest scope")
    require(manifest.get("device_types") == list(DEVICE_TYPES), "Unexpected device targets")
    pair_id = manifest.get("pair_id")
    require(isinstance(pair_id, str) and re.fullmatch(r"[0-9a-f]{64}", pair_id),
            "Missing pair identity")
    artifacts = manifest.get("artifacts", [])
    require(len(artifacts) == 2 and len(reports) == 3, "Two HAPs and three reports are required")
    builds = [artifact["build"] for artifact in artifacts]
    for build, stage in zip(builds, STAGES):
        require(build.get("stage") == stage and build.get("bundle_name") == BUNDLE_NAME
                and build.get("pair_id") == pair_id
                and build.get("device_types") == manifest["device_types"]
                and build.get("baseline_version_code") == STAGES["baseline"]["version_code"]
                and all(build.get(key) == value for key, value in STAGES[stage].items()),
                "Unexpected manifest build identity")
    for report, expected in zip(reports, (builds[0], builds[0], builds[1])):
        require(report.get("probe_schema") == 2 and report.get("runtime_platform") == "ohos",
                "Only completed OHOS schema-2 reports can be reviewed")
        require(report.get("sideload_build") == expected, "Report is from another build/pair")
        require(report.get("status") in ("core_pass_restart_pending", "core_checks_pass"),
                "Core checks did not complete successfully")
        events = report.get("events", [])
        for name in ("quickjs", "rhttp", "sqlite"):
            results = [event for event in events if event.get("type") == "result"
                       and event.get("id") == name]
            require(len(results) == 1 and results[0].get("status") == "pass",
                    "Missing or failing core result")
        done = [event for event in events if event.get("type") == "done"]
        require(len(done) == 1 and done[0].get("status") == report["status"],
                "Missing or inconsistent worker completion")
        require(not any(event.get("type") == "fatal" for event in events),
                "Report contains a fatal failure")
    launches = [report.get("launch_id") for report in reports]
    require(all(isinstance(value, str) and value for value in launches)
            and len(set(launches)) == 3, "Distinct process launches are required")
    states = [report.get("sideload_state", {}) for report in reports]
    marker = states[0].get("marker")
    require(isinstance(marker, str) and re.fullmatch(r"[0-9a-f]{32}", marker),
            "Missing baseline data marker")
    for index, state in enumerate(states):
        require(state.get("status") == ("upgrade_data_present" if index == 2 else "baseline_ready")
                and state.get("marker") == marker and state.get("pair_id") == pair_id
                and state.get("baseline_version_code") == STAGES["baseline"]["version_code"]
                and state.get("first_launch_id") == launches[0]
                and state.get("earlier_launch") is (index != 0),
                "Baseline data was missing, replaced, or from another pair")
        if index:
            require(reports[index]["status"] == "core_checks_pass", "Process restart is pending")
            restart = [event for event in reports[index]["events"]
                       if event.get("type") == "result" and event.get("id") == "process_restart"]
            require(len(restart) == 1 and restart[0].get("status") == "pass",
                    "SQLite process-restart check is pending")
    return {"status": "reported_checks_pass", "pair_id": pair_id,
            "scope": "Reported OHOS core, restart and synthetic upgrade-data checks only",
            "signing_identity_verified": False, "certificate_renewal_verified": False,
            "reader_integrated": False}


def read_json(path):
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Report is too large; review a minimal synthetic export")
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    for stage in ("baseline", "restart", "upgrade"):
        parser.add_argument(f"--{stage}", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = review(read_json(args.manifest),
                        [read_json(path) for path in (args.baseline, args.restart, args.upgrade)])
    except (ValueError, KeyError, TypeError, AttributeError, OSError):
        # Do not echo arbitrary report fields or private paths on failure.
        print(json.dumps({"status": "not_verified", "detail":
                          "Incomplete or inconsistent input; check the sideload checklist"}))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
