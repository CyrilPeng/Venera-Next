from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_security as security


class ReleaseSecurityTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 23, 4, tzinfo=timezone.utc)
        self.lock = b"Reviewed Cargo.lock\n"
        self.context = {"source_commit": "a" * 40}
        self.report = {"schema": 1, "passed": True, **self.context,
                       "lockfile_sha256": hashlib.sha256(self.lock).hexdigest(),
                       "cargo_audit_version": security.AUDIT_VERSION, "database_commit": "b" * 40,
                       "vulnerability_count": 0,
                       "scanned_at": self.now.isoformat()}
        self.blob = patch.object(security, "git_blob", return_value=self.lock)
        self.blob.start()
        self.addCleanup(self.blob.stop)
        policy = patch.object(security, "committed_policy", return_value=None)
        policy.start()
        self.addCleanup(policy.stop)

    def test_scan_must_pass_for_the_original_lock_and_expire_after_24_hours(self):
        security.check_report(self.report, Path("unused"), self.context, now=self.now)
        changes = ({"passed": False}, {"schema": True}, {"vulnerability_count": 1}, {"source_commit": "c" * 40},
                   {"lockfile_sha256": "0" * 64}, {"database_commit": "unknown"},
                   {"scanned_at": (self.now - timedelta(hours=24, seconds=1)).isoformat()},
                   {"scanned_at": (self.now + timedelta(minutes=6)).isoformat()},
                   {"scanned_at": "2026-11-23T04:00:00"})
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                security.check_report(self.report | change, Path("unused"), self.context, now=self.now)

    def test_unavailable_database_or_failed_audit_keeps_a_failure_receipt(self):
        for failure in ("network", "registry", "audit", "query"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                lock = root / security.LOCKFILE
                lock.parent.mkdir(parents=True)
                lock.write_bytes(self.lock)
                calls = []
                def run(command, **kwargs):
                    calls.append(command)
                    if command[:2] == ["git", "clone"]:
                        if failure == "network":
                            raise subprocess.CalledProcessError(128, command)
                        return subprocess.CompletedProcess(command, 0)
                    if command[:2] == ["cargo", "fetch"]:
                        return subprocess.CompletedProcess(command, 1 if failure == "registry" else 0, b"", b"Registry metadata")
                    if failure == "query":
                        return subprocess.CompletedProcess(command, 0, json.dumps({"vulnerabilities": {"count": 0}}).encode(),
                                                           b"error: couldn't check if the package is yanked: not found\n")
                    return subprocess.CompletedProcess(command, 1, json.dumps({"vulnerabilities": {"count": 1}}).encode(), b"Denied advisory")
                with patch.object(security, "source_context", return_value=self.context), \
                        patch.object(security.subprocess, "check_output", side_effect=[
                            ("cargo-audit " + security.AUDIT_VERSION).encode(), b"b" * 40]), \
                        patch.object(security.subprocess, "run", side_effect=run), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    security.scan(root, root / "evidence", {})
                receipt = json.loads((root / "evidence/security-report.json").read_text())
                self.assertFalse(receipt["passed"])
                audits = [command for command in calls if command[:2] == ["cargo", "audit"]]
                self.assertEqual(len(audits), 0 if failure in ("network", "registry") else 1)
                if audits:
                    self.assertIn("--no-fetch", audits[0])

    def test_successful_scan_queries_the_installed_binary_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / security.LOCKFILE
            lock.parent.mkdir(parents=True)
            lock.write_bytes(self.lock)

            def output(command, **kwargs):
                if command == ["cargo-audit", "--version"]:
                    return ("cargo-audit " + security.AUDIT_VERSION + "\n").encode()
                if command[:3] == ["cargo", "audit", "--version"]:
                    return ("cargo-audit-audit " + security.AUDIT_VERSION + "\n").encode()
                return b"b" * 40

            result = json.dumps({"vulnerabilities": {"count": 0}}).encode()
            with patch.object(security, "source_context", return_value=self.context), \
                    patch.object(security.subprocess, "check_output", side_effect=output), \
                    patch.object(security.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, result, b"")):
                security.scan(root, root / "evidence", {})
            receipt = json.loads((root / "evidence/security-report.json").read_text())
            self.assertTrue(receipt["passed"])
            self.assertEqual(receipt["vulnerability_count"], 0)
            self.assertEqual(receipt["cargo_audit_version"], security.AUDIT_VERSION)


if __name__ == "__main__":
    unittest.main()
