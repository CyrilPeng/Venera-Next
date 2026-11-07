"""Validate an exact mainline or legacy source before generating its HAP."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-rc\.\d+)?")


def validate_context(value, source_commit, environ):
    unified = value.get("schema") == 3
    fields = {"schema", "channel", "source_commit", "release_commit", "version", "build",
              "tag", "run_id", "tagged", "changelog_sha256", "changelog", "preview", "caller_version", "caller_build"}
    fields.add("source_mode" if unified else "main_baseline")
    hashes = ("source_commit", "release_commit") if unified else ("source_commit", "main_baseline", "release_commit")
    if (set(value) != fields or type(value["schema"]) is not int or value["schema"] not in (2, 3) or value["channel"] != "harmonyos-beta"
            or type(value["tagged"]) is not bool or type(value["preview"]) is not bool
            or any(not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{40}", value[key])
                   for key in hashes)
            or (unified and (value["source_mode"] != "release_commit" or value["source_commit"] != value["release_commit"]))
            or value["source_commit"] != source_commit
            or value["release_commit"] != environ.get("GITHUB_SHA", value["release_commit"])
            or not isinstance(value["changelog"], str)
            or hashlib.sha256(value["changelog"].encode()).hexdigest() != value["changelog_sha256"]):
        raise ValueError("Invalid source-bound HarmonyOS release context")
    version, build = value["version"], value["build"]
    validate_version(version, build)
    if (not isinstance(value["caller_version"], str) or not VERSION.fullmatch(value["caller_version"])
            or type(value["caller_build"]) is not int or not 3 < value["caller_build"] <= 2147483647):
        raise ValueError("Invalid caller release metadata")
    if value["preview"]:
        if value["tagged"] or environ.get("GITHUB_REF_TYPE") == "tag":
            raise ValueError("A release tag cannot use the next-candidate preview")
    if (unified or not value["preview"]) and (version, build) != (value["caller_version"], value["caller_build"]):
        raise ValueError("A release build must use the caller version and build")
    if value["tag"] != "v" + version or value["run_id"] != environ.get("GITHUB_RUN_ID", value["run_id"]):
        raise ValueError("Mismatched release tag/run")
    if value["tagged"] and (environ.get("GITHUB_REF_TYPE") != "tag"
                            or environ.get("GITHUB_REF_NAME") != value["tag"] or build < 245):
        raise ValueError("Unverified release-tag context")
    if not value["tagged"] and environ.get("GITHUB_REF_TYPE") == "tag":
        raise ValueError("A release tag cannot masquerade as a branch build")
    return value


def validate_version(version, build):
    if not isinstance(version, str) or not VERSION.fullmatch(version) or type(build) is not int or not 245 <= build <= 2147483647:
        raise ValueError("The next HarmonyOS reader requires a valid version and build number >=245")


def build_inputs():
    filename = os.environ.get("HARMONYOS_RELEASE_CONTEXT")
    if filename:
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        context = validate_context(json.loads(Path(filename).read_text(encoding="utf-8")), source, os.environ)
        version, build, changelog = context["version"], context["build"], context["changelog"]
        if context["preview"] or context["schema"] == 3:
            config = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
            if ((version, build) != (config["version"], config["build"])
                    or changelog != (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")):
                raise ValueError("Mainline and preview builds must use their source version and changelog")
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
