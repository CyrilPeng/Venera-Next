"""Use the caller's release version without rewriting the pinned reader source."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-rc\.\d+)?")


def validate_context(value, source_commit, environ):
    fields = {"schema", "channel", "source_commit", "main_baseline", "release_commit", "version", "build",
              "tag", "run_id", "tagged", "changelog_sha256", "changelog"}
    if (set(value) != fields or type(value["schema"]) is not int or value["schema"] != 1 or value["channel"] != "harmonyos-beta"
            or type(value["tagged"]) is not bool
            or any(not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{40}", value[key])
                   for key in ("source_commit", "main_baseline", "release_commit"))
            or value["source_commit"] != source_commit
            or value["release_commit"] != environ.get("GITHUB_SHA", value["release_commit"])
            or not isinstance(value["changelog"], str)
            or hashlib.sha256(value["changelog"].encode()).hexdigest() != value["changelog_sha256"]):
        raise ValueError("Invalid source-bound HarmonyOS release context")
    version, build = value["version"], value["build"]
    validate_version(version, build)
    if value["tag"] != "v" + version or value["run_id"] != environ.get("GITHUB_RUN_ID", value["run_id"]):
        raise ValueError("Mismatched release tag/run")
    if value["tagged"] and (environ.get("GITHUB_REF_TYPE") != "tag"
                            or environ.get("GITHUB_REF_NAME") != value["tag"] or build < 244):
        raise ValueError("Unverified release-tag context")
    if not value["tagged"] and environ.get("GITHUB_REF_TYPE") == "tag":
        raise ValueError("A release tag cannot masquerade as a branch build")
    return value


def validate_version(version, build):
    if not isinstance(version, str) or not VERSION.fullmatch(version) or type(build) is not int or not 3 < build <= 2147483647:
        raise ValueError("Invalid release version or non-increasing legacy HAP build number")


def build_inputs():
    filename = os.environ.get("HARMONYOS_RELEASE_CONTEXT")
    if filename:
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        context = validate_context(json.loads(Path(filename).read_text(encoding="utf-8")), source, os.environ)
        version, build, changelog = context["version"], context["build"], context["changelog"]
        release = {key: item for key, item in context.items() if key != "changelog"}
    else:
        if os.environ.get("GITHUB_REF_TYPE") == "tag":
            raise ValueError("Tagged HAP builds require a verified release context")
        config = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
        version, build = config["version"], config["build"]
        validate_version(version, build)
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        if re.findall(r"^version: ([^\r\n]+)", pubspec, re.M) != [f"{version}+{build}"]:
            raise ValueError("Branch release.json and pubspec versions differ")
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        release = None
    return {"version_name": version, "hap_version_name": version.split("-")[0], "version_code": build,
            "changelog": changelog, "release": release}
