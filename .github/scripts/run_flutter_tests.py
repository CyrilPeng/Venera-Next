"""Run an owned Flutter suite and retain actual machine events and case timings."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from test_suites import ROOT, application_tests, load_manifest, paths, select_suite
from test_execution import load_skip_policy, partition_default, validate_complete_arguments, validate_skips


def resolve_flutter(executable: str) -> str:
    # CreateProcess does not use PATHEXT for a bare command. PowerShell can
    # launch `flutter`, but subprocess needs its resolved flutter.bat path.
    resolved = shutil.which(executable)
    if resolved is None:
        raise FileNotFoundError(f"Flutter executable was not found: {executable}")
    return resolved


def test_process_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if os.name == "nt":
        # Hosted runners may expose TEMP through an 8.3 user-directory alias.
        # Fixtures need a physical root before they test aliases inside it.
        temporary_root = environment.get("RUNNER_TEMP") or tempfile.gettempdir()
        temporary = str(Path(temporary_root).resolve(strict=True))
        environment.update(TEMP=temporary, TMP=temporary, TMPDIR=temporary)
    return environment


class RunReport:
    def __init__(self, root: Path = ROOT):
        self.root = root.as_posix().rstrip("/")
        self.suites: dict[int, dict] = {}
        self.groups: dict[int, dict] = {}
        self.errors: list[dict] = []
        self.tests: dict[int, dict] = {}
        self.done: bool | None = None
        self.elapsed_ms = 0

    def event(self, event: dict) -> None:
        timestamp = event.get("time", 0)
        self.elapsed_ms = max(self.elapsed_ms, timestamp)
        kind = event.get("type")
        if kind == "suite":
            suite = event["suite"]
            path = suite["path"].replace("\\", "/")
            if path.lower().startswith(self.root.lower() + "/"):
                path = path[len(self.root) + 1:]
            if suite["id"] in self.suites:
                raise ValueError("Duplicate suite ID")
            self.suites[suite["id"]] = {"path": path, "start_ms": timestamp, "end_ms": timestamp}
        elif kind == "group":
            group = event["group"]
            if group["id"] in self.groups:
                raise ValueError("Duplicate group ID")
            self.groups[group["id"]] = group
        elif kind == "testStart":
            test = event["test"]
            if test["id"] in self.tests:
                raise ValueError("Duplicate test ID")
            if test["suiteID"] not in self.suites:
                raise ValueError("Unknown test suite")
            self.tests[test["id"]] = {"id": test["id"], "name": test["name"], "suite_id": test["suiteID"], "start_ms": timestamp,
                "group_ids": test.get("groupIDs", []), "metadata": test.get("metadata", {}),
                "root_line": test.get("root_line"), "root_url": test.get("root_url")}
        elif kind == "testDone":
            test = self.tests[event["testID"]]
            if "result" in test:
                raise ValueError("Duplicate test terminal event")
            test.update(result=event["result"], hidden=event.get("hidden", False),
                        skipped=event.get("skipped", False), duration_ms=timestamp - test["start_ms"])
            self.suites[test["suite_id"]]["end_ms"] = timestamp
        elif kind == "error":
            self.errors.append(event)
        elif kind == "done":
            if self.done is not None:
                raise ValueError("Duplicate run terminal event")
            self.done = event["success"]

    def summary(self) -> dict:
        cases = [test for test in self.tests.values() if "result" in test and not test["hidden"]]
        suite_rows = []
        for ident, suite in self.suites.items():
            selected = [case for case in cases if case["suite_id"] == ident]
            suite_rows.append({**suite, "suite_span_ms": suite["end_ms"] - suite["start_ms"],
                               "cases": len(selected), "skipped": sum(case["skipped"] for case in selected),
                               "failed": sum(case["result"] != "success" and not case["skipped"] for case in selected)})
        return {
            "schema_version": 2, "complete": self.done is not None, "success": self.done,
            "groups": list(self.groups.values()),
            "errors": self.errors,
            "unfinished_tests": [test for test in self.tests.values() if "result" not in test],
            "unknown_groups": sorted({ident for case in cases for ident in case["group_ids"] if ident not in self.groups}),
            "elapsed_ms": self.elapsed_ms, "cases": len(cases),
            "passed": sum(case["result"] == "success" and not case["skipped"] for case in cases),
            "skipped": sum(case["skipped"] for case in cases),
            "failed": sum(case["result"] != "success" and not case["skipped"] for case in cases),
            "suites": sorted(suite_rows, key=lambda suite: -suite["suite_span_ms"]),
            "tests": [{**case, "path": self.suites[case["suite_id"]]["path"],
                       "group_names": [self.groups[ident]["name"] for ident in case["group_ids"] if ident in self.groups]}
                      for case in cases],
        }


def run(command: list[str], output: Path, *, root: Path = ROOT, expected: list[str] | None = None,
        execution_group: str | None = None, skip_policy: dict | None = None,
        coverage_path: Path | None = None) -> int:
    output.mkdir(parents=True, exist_ok=True)
    if coverage_path is not None:
        coverage_path.parent.mkdir(parents=True, exist_ok=True)
        coverage_path.unlink(missing_ok=True)  # A failed new run must not reuse an old LCOV report.
    report = RunReport(root)
    environment = test_process_environment()
    started_at = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    last_update = started
    protocol_errors = []
    with (output / "events.jsonl").open("w", encoding="utf-8") as events, \
            (output / "console.log").open("w", encoding="utf-8") as console:
        process = subprocess.Popen(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", errors="replace")
        assert process.stdout is not None
        for line in process.stdout:
            console.write(line)
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                print(line, end="", flush=True)
                continue
            if isinstance(event, list) and event and all(
                    isinstance(row, dict) and row.get("event") == "test.startedProcess" for row in event):
                continue  # Retained in console.log; ordinary process starts are not test failures.
            if not isinstance(event, dict) or "type" not in event:
                print(line, end="", flush=True)
                continue
            events.write(line)
            try:
                report.event(event)
            except (KeyError, TypeError, ValueError) as error:
                message = f"Invalid machine event ({event['type']}): {error}"
                protocol_errors.append(message)
                print(message, flush=True)
            if event["type"] == "error":
                print(event.get("error", "Flutter test error"), flush=True)
                if event.get("stackTrace"):
                    print(event["stackTrace"], flush=True)
            if time.monotonic() - last_update >= 20:
                summary = report.summary()
                print(f"Flutter: {summary['passed']} passed, {summary['skipped']} skipped, "
                      f"{summary['failed']} failed; {int(time.monotonic() - started)}s elapsed", flush=True)
                last_update = time.monotonic()
        process.stdout.close()
        exit_code = process.wait()
    summary = report.summary()
    loaded = {suite["path"] for suite in summary["suites"]}
    missing = sorted(set(expected or []) - loaded)
    duplicates = sorted(path for path, count in Counter(row["path"] for row in summary["suites"]).items() if count > 1)
    unexpected = sorted(loaded - set(expected)) if expected is not None else []
    platform = {"win32": "windows", "darwin": "macos"}.get(sys.platform, sys.platform)
    skips = validate_skips(summary, skip_policy, platform, expected) if skip_policy is not None else None
    git = shutil.which("git")
    commit = subprocess.run([git, "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True) if git else None
    manifest_path = root / "test/suites.json"
    summary.update(execution_group=execution_group, platform=platform, started_at=started_at,
                   finished_at=datetime.now(timezone.utc).isoformat(),
                   source_commit=commit.stdout.strip() if commit is not None and commit.returncode == 0 else None,
                   suite_manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest() if manifest_path.is_file() else None,
                   coverage_requested=coverage_path is not None,
                   coverage_sha256=hashlib.sha256(coverage_path.read_bytes()).hexdigest() if coverage_path is not None and coverage_path.is_file() else None,
                   skip_validation=skips, unexpected_files=unexpected, duplicate_files=duplicates)
    summary.update(expected_files=expected, missing_files=missing, protocol_errors=protocol_errors,
                   zero_case_files=[suite["path"] for suite in summary["suites"] if not suite["cases"]])
    summary.update(command=command, exit_code=exit_code, wall_seconds=round(time.monotonic() - started, 3),
                   temporary_directory=environment.get("TMP") if os.name == "nt" else None)
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Flutter suite: {summary['passed']} passed, {summary['skipped']} skipped, "
          f"{summary['failed']} failed; report={output / 'summary.json'}", flush=True)
    if missing:
        print(f"Selected test files were not loaded: {missing}", flush=True)
    integrity_failures = (missing or unexpected or duplicates or protocol_errors or summary["zero_case_files"] or
                          summary["unfinished_tests"] or summary["unknown_groups"] or not summary["cases"] or
                          summary["failed"] or summary["errors"] or
                          coverage_path is not None and not coverage_path.is_file() or
                          skips is not None and (skips["unexpected"] or skips["stale"]))
    if integrity_failures:
        print(f"Test execution integrity failed: {integrity_failures}", flush=True)
    if not summary["complete"] or summary["success"] is not True or integrity_failures:
        return exit_code or 1
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", default="default")
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--partition")
    parser.add_argument("--coverage-path", type=Path, help="LCOV output for this execution group")
    parser.add_argument("--concurrency", type=int)
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()
    manifest = load_manifest()
    suite = manifest["suites"].get(args.suite)
    platform = {"win32": "windows", "darwin": "macos"}.get(sys.platform, sys.platform)
    if suite is None or platform not in suite["platforms"]:
        raise ValueError(f"Unsupported suite/platform: {args.suite}/{sys.platform}")
    sources = {path: (ROOT / path).read_text(encoding="utf-8") for path in application_tests(paths())}
    selected = select_suite(manifest, args.suite, sources)
    if args.partition is not None:
        partitions = partition_default(manifest, sources)
        if args.suite != "default" or args.partition not in partitions:
            raise ValueError(f"Unknown default execution partition: {args.partition}")
        selected = partitions[args.partition]
    if args.files:
        invalid = sorted(set(args.files) - set(selected))
        if invalid:
            raise ValueError(f"Files are not owned by {args.suite}: {invalid}")
        selected = sorted(set(args.files))
    command = [resolve_flutter(args.flutter), "test", "--no-pub", "--machine", *suite["arguments"]]
    coverage_path = None
    if args.coverage:
        coverage_path = args.coverage_path or ROOT / "coverage/lcov.info"
        command.extend(["--coverage", "--coverage-path", str(coverage_path)])
    elif args.coverage_path is not None:
        raise ValueError("--coverage-path requires --coverage")
    if args.concurrency is not None:
        if args.concurrency < 1:
            raise ValueError("Concurrency must be positive")
        command.extend(["--concurrency", str(args.concurrency)])
    # The default directory also keeps Windows batch command lines below their
    # length limit. Its discovery is checked against the complete catalog.
    if not args.files and set(selected) == set(sources):
        command.append("test")
    else:
        command.extend(selected)
    validate_complete_arguments(command, coverage=args.coverage)
    output = args.output or ROOT / "build/test-audit" / args.suite
    return run(command, output, expected=selected, execution_group=args.partition or args.suite,
               skip_policy=load_skip_policy(manifest, sources=sources), coverage_path=coverage_path)


if __name__ == "__main__":
    raise SystemExit(main())
