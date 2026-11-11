#!/usr/bin/env python3
"""Finish an exact tagged build with reviewed tooling and its original assets."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil

import android_tv_build as android
import harmonyos_release as release


REQUIRED_JOBS = {
    "Release_Metadata", "Quality / analyze", "Quality / Flutter 测试与覆盖率",
    "Quality / Apple 目录授权与跨会话恢复", "Quality / Rhttp 原生回调生命周期",
    "Quality / iOS Rhttp 原生依赖兼容性", "Quality / Android 文档存储真实 Provider 回归",
    "HarmonyOS / unsigned-hap", "Build / Build_Linux_ARM64", "Build / Build_Linux_x64",
    "Build / Build_IOS", "Build / Build_MacOS", "Build / Build_Windows",
    "Build / Build_Android (mobile)", "Build / Build_Android (tv)",
}
TOOLING_FILES = {
    ".github/scripts/harmonyos_release.py", ".github/scripts/resume_release.py",
    ".github/scripts/tests/test_harmonyos_release.py", ".github/scripts/tests/test_resume_release.py",
    ".github/workflows/resume-release.yml", "CHANGELOG.md",
    "doc/development/release_readiness.md", "doc/development/harmonyos_releases.zh.md",
    "doc/development/harmonyos_releases.en.md",
}
RELEASE_ARTIFACTS = {
    "harmonyos-release", "macos_build", "ios_build", "windows_build", "deb_build",
    "arch_build", "deb_arm64_build", "linux_extra_arm64", "linux_extra_x64",
    "android-mobile-manifest", "android-tv-manifest",
    *(f"{prefix}{abi}" for prefix in ("apk-", "tv-apk-")
      for abi in ("arm64-v8a", "armeabi-v7a", "x86_64", "universal")),
}


def validate_build_run(run, jobs, run_id):
    if (not isinstance(run, dict) or type(run.get("id")) is not int or run.get("id") != run_id
            or run.get("event") != "push" or run.get("path") != ".github/workflows/main.yml"
            or run.get("status") != "completed" or run.get("conclusion") not in ("failure", "success")
            or not isinstance(run.get("head_sha"), str) or not release.SHA.fullmatch(run["head_sha"])
            or not isinstance(run.get("head_branch"), str)
            or not re.fullmatch(r"v\d+\.\d+\.\d+(?:-rc\.\d+)?", run["head_branch"])
            or not isinstance(run.get("repository"), dict)
            or run["repository"].get("full_name", "").lower() != release.REPOSITORY.lower()):
        raise ValueError("Recovery requires an exact completed tagged full-build run from this repository")
    if not isinstance(jobs, list) or any(not isinstance(job, dict) for job in jobs):
        raise ValueError("Invalid original build job inventory")
    for name in REQUIRED_JOBS:
        matches = [job for job in jobs if job.get("name") == name]
        if (len(matches) != 1 or matches[0].get("status") != "completed"
                or matches[0].get("conclusion") != "success"):
            raise ValueError("Original source/build gate did not pass: " + name)
    if any(job.get("status") != "completed" or (
            job.get("name") != "Release" and job.get("conclusion") not in ("success", "skipped")) for job in jobs):
        raise ValueError("Only a failed publishing job may be recovered; original builds must all pass")
    return run


def original_build(tooling_root, run_id):
    if type(run_id) is not int or run_id <= 0:
        raise ValueError("Invalid original run ID")
    run = json.loads(release.gh("api", f"repos/{release.REPOSITORY}/actions/runs/{run_id}"))
    pages = json.loads(release.gh("api", "--paginate", "--slurp",
                                  f"repos/{release.REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"))
    if not isinstance(pages, list) or any(not isinstance(page, dict) or not isinstance(page.get("jobs"), list) for page in pages):
        raise ValueError("Invalid paginated original job response")
    validate_build_run(run, [job for page in pages for job in page["jobs"]], run_id)
    head = release.git(tooling_root, "rev-parse", "HEAD").decode().strip()
    changed = release.git(tooling_root, "diff", "--name-only", "-z", run["head_sha"], head, "--")
    paths = {path.decode() for path in changed.split(b"\0") if path}
    if paths - TOOLING_FILES:
        raise ValueError("Recovery tooling must not change runtime, dependencies, version or build inputs: "
                         + ", ".join(sorted(paths - TOOLING_FILES)))
    if release.git(tooling_root, "diff", "--name-only", "HEAD", "--"):
        raise ValueError("Recovery tooling has uncommitted changes")
    if release.git(tooling_root, "ls-files", "--others", "--exclude-standard"):
        raise ValueError("Recovery tooling has untracked inputs")
    return run, head


def original_environment(run):
    # These identify the validated compiler run, not the recovery workflow.
    return {"GITHUB_SHA": run["head_sha"], "GITHUB_RUN_ID": str(run["id"]),
            "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": run["head_branch"]}


def collect_artifacts(downloaded, output):
    """Collect only named compiler artifacts; diagnostics cannot become packages."""
    for name in sorted(RELEASE_ARTIFACTS):
        directory = downloaded / name
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError("Missing original build artifact: " + name)
        destination = output / "harmonyos" if name == "harmonyos-release" else output
        destination.mkdir(parents=True, exist_ok=True)
        count = 0
        for source in sorted(directory.rglob("*")):
            if source.is_symlink():
                raise ValueError("Linked original artifact input: " + str(source))
            if not source.is_file():
                continue
            target = destination / source.name
            if target.exists():
                raise ValueError("Duplicate original asset: " + target.name)
            shutil.copyfile(source, target)
            count += 1
        if not count:
            raise ValueError("Empty original build artifact: " + name)


def check_identity_and_notes(remote, expected, notes):
    if (remote.get("target_commitish") != expected["release_commit"]
            or not isinstance(remote.get("body"), str)
            or remote["body"].replace("\r\n", "\n").strip() != notes.strip()):
        raise ValueError("Release source or notes differ from the original tag")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("source", "publish"))
    parser.add_argument("--run", type=int, required=True)
    parser.add_argument("--tooling-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--release-files", type=Path, nargs="+")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    run, tooling_head = original_build(args.tooling_root, args.run)
    if args.action == "source":
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"source_commit={run['head_sha']}\ntag={run['head_branch']}\n")
        print(json.dumps({"run_id": run["id"], "source_commit": run["head_sha"],
                          "tag": run["head_branch"], "tooling_commit": tooling_head}))
        return
    if not all((args.source_root, args.artifacts, args.notes_file, args.release_files, args.receipt)):
        parser.error("Publication requires source, original artifacts, notes, files and a receipt path")
    if not args.notes_file.is_file() or args.notes_file.is_symlink():
        raise ValueError("Missing original release notes")
    notes = args.notes_file.read_text(encoding="utf-8-sig")
    if not notes.strip():
        raise ValueError("Empty original release notes")
    expected = release.context(args.source_root, args.source_root, original_environment(run))
    assets = release.verify_bundle(args.artifacts, expected, args.source_root)
    files = release.release_file_records(args.release_files)
    remote_files = release.github_release_file_records(files)
    remote = release.read_remote_release(expected["tag"], published=False)
    check_identity_and_notes(remote, expected, notes)
    release.check_draft_files(remote, expected, files)
    release.check_remote_release(remote, expected, assets, published=False)
    # Verify both Android catalogs against the compiler's exact source/run.
    android.verify_release(args.artifacts.parent,
                           release.blob(args.source_root, expected["source_commit"], "pubspec.yaml").decode("utf-8-sig"),
                           {"GITHUB_SHA": run["head_sha"], "GITHUB_REF": "refs/tags/" + expected["tag"],
                            "GITHUB_EVENT_NAME": "push"})
    ready = release.check_runtime(expected, assets, allow_pending=True)
    receipt = {"schema": 1, "original_run": run["id"], "source_commit": run["head_sha"],
               "tag": expected["tag"], "tooling_commit": tooling_head,
               "recovery_run": os.environ.get("GITHUB_RUN_ID"), "ready": ready,
               "files": files, "github_files": remote_files, "published": False}
    if ready:
        options = ["--latest=false"] if "-" in expected["version"] else []
        release.gh("release", "edit", expected["tag"], "--repo", release.REPOSITORY, "--draft=false", *options)
        published = release.read_remote_release(expected["tag"], published=True)
        if published.get("id") != remote.get("id"):
            raise ValueError("Release identity changed during publication")
        check_identity_and_notes(published, expected, notes)
        release.check_draft_files(published, expected, files)
        release.check_remote_release(published, expected, assets, published=True)
        release.check_runtime(expected, assets, published=True)
        receipt["published"] = True
        receipt["release_url"] = published["html_url"]
    args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in receipt.items() if key not in ("files", "github_files")}))


if __name__ == "__main__":
    main()
