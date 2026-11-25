#!/usr/bin/env python3
"""Fresh RustSec scans and source-bound, expiring release security receipts."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from release_assets import committed_policy, git_blob, require, source_context, text, write_receipt


LOCKFILE = "packages/rhttp/rust/Cargo.lock"
AUDIT_VERSION = "0.22.2"
MAX_AGE_HOURS = 24


def check_report(report, root, context, *, now=None):
    current = now or datetime.now(timezone.utc)
    policy = committed_policy(root, context["source_commit"])
    max_age = policy["security_max_age_hours"] if policy else MAX_AGE_HOURS
    require(type(report.get("schema")) is int and report["schema"] == 1 and report.get("passed") is True
            and report.get("source_commit") == context["source_commit"]
            and report.get("lockfile_sha256") == hashlib.sha256(git_blob(root, context["source_commit"], LOCKFILE)).hexdigest()
            and report.get("cargo_audit_version") == AUDIT_VERSION
            and type(report.get("vulnerability_count")) is int and report["vulnerability_count"] == 0
            and isinstance(report.get("database_commit"), str) and re.fullmatch(r"[0-9a-f]{40}", report["database_commit"]),
            "Security scan is missing, failed or identifies a different source/lockfile")
    try:
        scanned = datetime.fromisoformat(report["scanned_at"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Security scan needs an actual timezone-qualified timestamp") from error
    require(scanned.tzinfo is not None and current - timedelta(hours=max_age) <= scanned <= current + timedelta(minutes=5),
            "Security scan expired; rescan the original lockfile before publication")
    return report


def scan(root, output, environ):
    context = source_context(root, environ)
    lock = git_blob(root, context["source_commit"], LOCKFILE)
    require(text((root / LOCKFILE).read_bytes()) == text(lock), "Audit lockfile differs from the committed source")
    output.mkdir(parents=True, exist_ok=True)
    report = {"schema": 1, "source_commit": context["source_commit"], "cargo_audit_version": AUDIT_VERSION,
              "lockfile_sha256": hashlib.sha256(lock).hexdigest(), "passed": False,
              "scanned_at": datetime.now(timezone.utc).isoformat()}
    try:
        # The Cargo subcommand reports `cargo-audit-audit`; query the installed binary itself.
        version = subprocess.check_output(["cargo-audit", "--version"], timeout=30).decode().strip()
        require(version == "cargo-audit " + AUDIT_VERSION, "Unexpected cargo-audit version: " + version)
        with tempfile.TemporaryDirectory(prefix="release-rustsec-") as directory:
            database = Path(directory) / "advisory-db"
            # A fresh clone fails closed on network errors, with no cached-database fallback.
            subprocess.run(["git", "clone", "--quiet", "--depth=1", "https://github.com/RustSec/advisory-db.git", str(database)],
                           check=True, timeout=180)
            report["database_commit"] = subprocess.check_output(["git", "-C", str(database), "rev-parse", "HEAD"], timeout=30).decode().strip()
            # --no-fetch also disables index updates for yanked checks; prepare the full locked index first.
            fetched = subprocess.run(["cargo", "fetch", "--locked", "--manifest-path", str(root / "packages/rhttp/rust/Cargo.toml")],
                                     capture_output=True, timeout=300)
            (output / "cargo-fetch.log").write_bytes(fetched.stdout + fetched.stderr)
            report["registry_metadata_checked"] = fetched.returncode == 0
            require(report["registry_metadata_checked"], "Locked registry metadata refresh failed; see cargo-fetch.log")
            result = subprocess.run(["cargo", "audit", "--file", str(root / LOCKFILE), "--db", str(database),
                                     "--no-fetch", "--json", "--color", "never", "--deny", "unsound"], capture_output=True, timeout=300)
            (output / "rust-audit.json").write_bytes(result.stdout)
            (output / "rust-audit.log").write_bytes(result.stderr)
            raw = json.loads(result.stdout)
            report["vulnerability_count"] = raw.get("vulnerabilities", {}).get("count")
            report["passed"] = (result.returncode == 0 and report["vulnerability_count"] == 0
                                and not re.search(rb"(?m)^error:", result.stderr))
            require(report["passed"], "Rust dependency audit failed; see rust-audit.json and rust-audit.log")
            check_report(report, root, context)
    finally:
        write_receipt(output / "security-report.json", report)
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=Path("build/security"))
    args = parser.parse_args()
    scan(args.root.resolve(), args.output, os.environ)


if __name__ == "__main__":
    main()
