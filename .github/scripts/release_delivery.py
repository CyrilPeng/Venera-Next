#!/usr/bin/env python3
"""Verify published bytes and rehearse draft delivery without a public release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import harmonyos_release as harmony
import release_assets as assets
from release_security import check_report


REPOSITORY = harmony.REPOSITORY
PROOF = "release-verification.json"
INTERRUPTED = 75


def gh(*arguments):
    return harmony.gh(*arguments)


def read_release(identifier):
    remote = json.loads(gh("api", f"repos/{REPOSITORY}/releases/{identifier}"))
    assets.require(type(identifier) is int and identifier > 0 and remote.get("id") == identifier,
                   "Release identity changed")
    return remote


def find_release(tag):
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases?per_page=100"))
    assets.require(isinstance(pages, list) and all(isinstance(page, list) for page in pages), "Invalid release list")
    matches = [item for page in pages for item in page if item.get("tag_name") == tag]
    assets.require(len(matches) <= 1, "Duplicate release tag")
    return read_release(matches[0]["id"]) if matches else None


def validate_inputs(root, directory, manifest_path, environ, *, security=None):
    context = assets.source_context(root, environ)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = assets.expected_files(context)
    names = set().union(*expected.values())
    assets.require(all(manifest.get(key) == value for key, value in context.items())
                   and manifest.get("package_checks") == {name: "pass" for name in assets.PLATFORMS}
                   and set(manifest.get("files", {})) == names, "Incomplete or foreign full-build verification manifest")
    paths = assets.locate_files([directory], names)
    records = assets.file_records(paths.values())
    assets.require(records == manifest["files"] and manifest.get("github_files") == assets.github_file_records(records),
                   "Package bytes differ from the verified original build")
    check_report(security if security is not None else manifest.get("security", {}), root, context)
    paths[PROOF] = manifest_path
    records.update(assets.file_records([manifest_path]))
    return context, paths, records


def upload_asset(identifier, path):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    assets.require(token, "Draft upload requires the workflow's repository token")
    endpoint = f"https://uploads.github.com/repos/{REPOSITORY}/releases/{identifier}/assets?" + urlencode({"name": path.name})
    request = Request(endpoint, data=path.read_bytes(), method="POST", headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/octet-stream",
        "Accept": "application/vnd.github+json", "User-Agent": "VeneraNext-release-verification"})
    with urlopen(request, timeout=180) as response:
        return json.load(response)


def upload_missing(remote, paths, records, *, limit=None, optional=()):
    missing = assets.check_remote_files(remote, records, partial=True, optional=optional)
    # Include Linux RC names in an interrupted upload so the real API normalization is exercised.
    ordered = sorted(paths, key=lambda name: ("~" not in name, name))
    uploaded = 0
    for name in ordered:
        if name.replace("~", ".") not in missing:
            continue
        upload_asset(remote["id"], paths[name])
        uploaded += 1
        if limit is not None and uploaded >= limit:
            break
    result = read_release(remote["id"])
    assets.check_remote_files(result, records, partial=limit is not None, optional=optional)
    return result


def download_files(remote, records):
    assets.check_remote_files(remote, records, optional=(harmony.RUNTIME_REPORT,))
    expected = assets.github_file_records(records)
    with tempfile.TemporaryDirectory(prefix="venera-release-download-") as temporary:
        for asset in remote["assets"]:
            name = asset["name"]
            if name not in expected:
                continue
            identifier = asset.get("id")
            assets.require(type(identifier) is int and identifier > 0, "Invalid uploaded asset ID")
            path = Path(temporary) / name
            with path.open("wb") as stream:
                subprocess.run(["gh", "api", f"repos/{REPOSITORY}/releases/assets/{identifier}",
                                "-H", "Accept: application/octet-stream"], stdout=stream, check=True, timeout=180)
            assets.require(assets.file_records([path])[name] == expected[name], "Downloaded bytes differ: " + name)
    return len(expected)


def rehearsal_identity(context, environ):
    assets.require(environ.get("GITHUB_ACTIONS") == "true" and environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
                   and environ.get("GITHUB_REF_TYPE") == "branch" and not environ.get("GITHUB_REF", "").startswith("refs/tags/")
                   and environ.get("GITHUB_REPOSITORY") == REPOSITORY
                   and re.fullmatch(r"[1-9]\d*", context["run_id"]), "Rehearsal requires a repository branch dispatch")
    attempt = environ.get("GITHUB_RUN_ATTEMPT", "1")
    assets.require(re.fullmatch(r"[1-9]\d*", attempt), "Invalid rehearsal attempt")
    return f"rehearsal-{context['run_id']}-{attempt}"


def check_rehearsal(remote, context, tag):
    assets.require(remote.get("tag_name") == tag and tag.startswith("rehearsal-") and remote.get("draft") is True
                   and remote.get("prerelease") is True and remote.get("target_commitish") == context["source_commit"],
                   "Rehearsal draft changed identity, source or visibility")


def rehearse(root, directory, manifest, receipt, environ, *, resume=False, interrupt=False):
    context, paths, records = validate_inputs(root, directory, manifest, environ)
    tag = rehearsal_identity(context, environ)
    manifest_digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
    if resume:
        state = json.loads(receipt.read_text())
        assets.require(state.get("tag") == tag and state.get("source_commit") == context["source_commit"]
                       and state.get("manifest_sha256") == manifest_digest and state.get("state") == "interrupted_after_upload",
                       "Recovery does not identify the interrupted rehearsal and original packages")
        remote = read_release(state["release_id"])
    else:
        assets.require(find_release(tag) is None, "Rehearsal draft already exists; use its recorded recovery state")
        remote = json.loads(gh("api", "--method", "POST", f"repos/{REPOSITORY}/releases", "-f", "tag_name=" + tag,
                              "-f", "target_commitish=" + context["source_commit"], "-F", "draft=true", "-F", "prerelease=true",
                              "-f", "make_latest=false", "-f", "name=Internal release rehearsal",
                              "-f", "body=Internal draft verification. This rehearsal must never be published."))
        state = context | {"tag": tag, "release_id": remote["id"], "manifest_sha256": manifest_digest,
                           "state": "created", "published": False, "channels": "skipped"}
        assets.write_receipt(receipt, state)
    check_rehearsal(remote, context, tag)
    previous = {item["name"]: item["id"] for item in remote["assets"]}
    remote = upload_missing(remote, paths, records, limit=1 if interrupt else None)
    check_rehearsal(remote, context, tag)
    assets.require(all(next(item["id"] for item in remote["assets"] if item["name"] == name) == identifier
                       for name, identifier in previous.items()), "Recovery replaced an existing original asset")
    if interrupt:
        state.update(state="interrupted_after_upload", preserved_assets={item["name"]: item["id"] for item in remote["assets"]})
        assets.write_receipt(receipt, state)
        return INTERRUPTED
    count = download_files(remote, records)
    if resume:
        assets.require(all(next(item["id"] for item in remote["assets"] if item["name"] == name) == identifier
                           for name, identifier in state["preserved_assets"].items()), "Interrupted-upload recovery replaced an asset")
    state.update(state="verified", downloads_verified=count, recovery_verified=resume, files=records)
    assets.write_receipt(receipt, state)
    return 0


def cleanup_rehearsal(receipt, environ):
    if not receipt.exists():
        return
    state = json.loads(receipt.read_text())
    tag = rehearsal_identity(state, environ)
    assets.require(state.get("tag") == tag, "Cleanup does not own this rehearsal")
    if state.get("cleaned") is True:
        return
    remote = read_release(state["release_id"])
    check_rehearsal(remote, state, tag)
    gh("api", "--method", "DELETE", f"repos/{REPOSITORY}/releases/{remote['id']}")
    state["cleaned"] = True
    assets.write_receipt(receipt, state)


def production_inputs(root, source, directory, manifest, environ, security):
    context, paths, records = validate_inputs(root, directory, manifest, environ, security=security)
    assets.require(environ.get("GITHUB_REF_TYPE") == "tag" and environ.get("GITHUB_REF_NAME") == "v" + context["version"],
                   "Production delivery requires the exact version tag")
    expected = harmony.context(root, source, environ)
    hap = harmony.publication_assets(directory / "harmonyos", expected, source)
    if hap:
        additions = [directory / "harmonyos" / name for name in hap]
        paths.update({path.name: path for path in additions})
        records.update(assets.file_records(additions))
    return context, paths, records, expected, hap


def prepare_production(root, source, directory, manifest, notes, receipt, environ, *, security=None):
    context, paths, records, expected, hap = production_inputs(root, source, directory, manifest, environ, security)
    remote = find_release(expected["tag"])
    if remote is None:
        arguments = ["release", "create", expected["tag"], "--repo", REPOSITORY, "--verify-tag", "--target",
                     context["source_commit"], "--title", expected["tag"], "--notes-file", str(notes), "--draft"]
        if "-" in context["version"]:
            arguments.extend(("--prerelease", "--latest=false"))
        gh(*arguments)
        remote = find_release(expected["tag"])
    assets.require(remote is not None and remote.get("target_commitish") == context["source_commit"]
                   and isinstance(remote.get("body"), str) and remote["body"].replace("\r\n", "\n").strip() == notes.read_text().strip()
                   and remote.get("prerelease") is ("-" in context["version"]), "Release source, notes or channel differs")
    optional = (harmony.RUNTIME_REPORT,) if harmony.bundles_harmonyos(expected) else ()
    if remote.get("draft") is True:
        remote = upload_missing(remote, paths, records, optional=optional)
    else:
        assets.check_remote_files(remote, records, optional=optional)
    harmony.check_remote_release(remote, expected, hap, published=remote.get("draft") is False)
    assets.write_receipt(receipt, context | {"release_id": remote["id"], "published": remote.get("draft") is False,
                                           "state": "prepared", "channels": "pending" if remote.get("draft") is False else "skipped"})
    return 0


def production(root, source, directory, manifest, notes, receipt, environ, *, publish=False, security=None):
    context, paths, records, expected, hap = production_inputs(root, source, directory, manifest, environ, security)
    remote = find_release(expected["tag"])
    assets.require(remote is not None and remote.get("target_commitish") == context["source_commit"]
                   and isinstance(remote.get("body"), str) and remote["body"].replace("\r\n", "\n").strip() == notes.read_text().strip(),
                   "Release source or notes differ from the original build")
    published = remote.get("draft") is False
    harmony.check_remote_release(remote, expected, hap, published=published)
    assets.check_remote_files(remote, records, optional=(harmony.RUNTIME_REPORT,))
    ready = harmony.check_runtime(expected, hap, allow_pending=not published, published=published)
    if publish and ready and not published:
        download_files(remote, records)
        check_report(security if security is not None else json.loads(manifest.read_text())["security"], root, context)
        gh("release", "edit", expected["tag"], "--repo", REPOSITORY, "--draft=false",
           "--latest=false" if "-" in context["version"] else "--latest=true")
        remote = read_release(remote["id"])
        assets.require(remote.get("body", "").replace("\r\n", "\n").strip() == notes.read_text().strip(),
                       "Release notes changed during publication")
        harmony.check_remote_release(remote, expected, hap, published=True)
        published = True
        harmony.check_runtime(expected, hap, published=True)
    count = download_files(remote, records)
    result = context | {"release_id": remote["id"], "release_url": remote["html_url"], "published": published,
                        "ready": ready,
                        "state": "published_verified" if published else "draft_verified" if ready else "acceptance_pending",
                        "downloads_verified": count, "channels": "pending" if published and "-" not in context["version"] else "skipped"}
    assets.write_receipt(receipt, result)
    return 0


def summary(receipt):
    if receipt.exists() and os.environ.get("GITHUB_STEP_SUMMARY"):
        state = json.loads(receipt.read_text())
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
            stream.write("## Release delivery verification\n\n```json\n" + json.dumps(state, ensure_ascii=False, indent=2) + "\n```\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("rehearse", "resume-rehearsal", "cleanup-rehearsal", "prepare-draft", "verify-draft", "publish"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--security-report", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--interrupt-after-upload", action="store_true")
    args = parser.parse_args()
    if args.action == "cleanup-rehearsal":
        cleanup_rehearsal(args.receipt, os.environ)
        summary(args.receipt)
        return
    if args.directory is None or args.manifest is None:
        parser.error("--directory and --manifest are required")
    if args.action in ("rehearse", "resume-rehearsal"):
        status = rehearse(args.root, args.directory, args.manifest, args.receipt, os.environ,
                          resume=args.action == "resume-rehearsal", interrupt=args.interrupt_after_upload)
    else:
        if args.notes_file is None or args.interrupt_after_upload:
            parser.error("production delivery requires --notes-file and cannot inject an interruption")
        security = json.loads(args.security_report.read_text()) if args.security_report else None
        if args.action == "prepare-draft":
            status = prepare_production(args.root, args.source_root or args.root, args.directory, args.manifest,
                                        args.notes_file, args.receipt, os.environ, security=security)
        else:
            status = production(args.root, args.source_root or args.root, args.directory, args.manifest, args.notes_file,
                                args.receipt, os.environ, publish=args.action == "publish", security=security)
            if os.environ.get("GITHUB_OUTPUT"):
                with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                    state = json.loads(args.receipt.read_text())
                    output.write("ready=" + str(state["ready"]).lower() + "\n")
    summary(args.receipt)
    raise SystemExit(status)


if __name__ == "__main__":
    main()
