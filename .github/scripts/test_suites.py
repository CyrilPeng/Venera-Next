"""Inventory and validate test execution ownership without adding a test framework."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "test/suites.json"
IMPORT = re.compile(r"(?:import|export)\s+['\"]([^'\"]+)['\"]")
WINDOWS_SKIP = re.compile(r"skip:\s*!Platform\.isWindows")


def paths(root: Path = ROOT) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, stdout=subprocess.PIPE,
    )
    return sorted({path for path in result.stdout.decode("utf-8").split("\0") if path})


def matches(path: str, pattern: str) -> bool:
    if not pattern or pattern.startswith(("/", "\\")) or ".." in pattern.split("/"):
        raise ValueError(f"Unsafe test pattern: {pattern!r}")
    expression = re.escape(pattern).replace(r"\*\*/", "(?:.*/)?")
    expression = expression.replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(expression, path) is not None


def load_manifest(path: Path = MANIFEST) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or not isinstance(manifest.get("suites"), dict):
        raise ValueError("Unsupported or missing test suite schema")
    return manifest


def application_tests(all_paths: list[str]) -> list[str]:
    return [path for path in all_paths if path.startswith("test/") and path.endswith("_test.dart")]


def select_suite(manifest: dict, name: str, sources: dict[str, str], *, root: Path = ROOT) -> list[str]:
    if name not in manifest["suites"]:
        raise ValueError(f"Unknown test suite: {name}")
    suite = manifest["suites"][name]
    patterns = suite.get("include", [])
    expressions = [re.compile(value) for value in suite.get("source_matches", [])]
    dependency_sources = dict(sources)

    def source_matches(path: str) -> bool:
        # A test can reach a native/platform fixture through multiple support
        # imports. Moving preparation out of the test must not remove its owner.
        pending = [path]
        visited = set()
        while pending:
            current = pending.pop()
            if current in visited:
                continue
            visited.add(current)
            source = dependency_sources[current]
            if any(expression.search(source) for expression in expressions):
                return True
            for target in IMPORT.findall(source):
                if target.startswith(("dart:", "package:")) or not target.endswith(".dart"):
                    continue
                resolved = (root / current).parent.joinpath(target).resolve()
                try:
                    relative = resolved.relative_to(root.resolve()).as_posix()
                except ValueError:
                    continue
                # Package main() wrappers have their own explicit ownership.
                # Only follow helpers inside the application test tree here.
                if not relative.startswith("test/") or not resolved.is_file():
                    continue
                if relative not in dependency_sources:
                    dependency_sources[relative] = resolved.read_text(encoding="utf-8")
                pending.append(relative)
        return False

    for pattern in patterns:
        if not any(matches(path, pattern) for path in sources):
            raise ValueError(f"{name}: stale or empty test pattern: {pattern}")
    selected = [path for path, source in sources.items() if
                any(matches(path, pattern) for pattern in patterns) or
                expressions and source_matches(path)]
    if not selected:
        raise ValueError(f"{name}: suite selected no tests")
    return sorted(selected)


def is_external_test(path: str, source: str) -> bool:
    name = Path(path).name
    return (
        (name.startswith("test_") and path.endswith(".py") and re.search(r"^\s*def test_", source, re.MULTILINE) is not None)
        or name.startswith("test_") and path.endswith((".mjs", ".ps1", ".sh"))
        or path.endswith(("_test.dart", "_test.cpp", "_test.kt", "Tests.swift", "Test.kt"))
        or (path.endswith(".rs") and re.search(r"#\[(?:[\w:]*test|cfg\(test\))\]", source) is not None)
        or path.endswith(".dart.template") and "/test/" in path
        or path.endswith("_probe.dart") and path.startswith("tool/")
    )


def collect(root: Path = ROOT, manifest: dict | None = None, *, strict_imports: bool = False) -> dict:
    manifest = manifest or load_manifest(root / "test/suites.json")
    all_paths = paths(root)
    tests = application_tests(all_paths)
    sources = {path: (root / path).read_text(encoding="utf-8") for path in tests}
    selections = {name: select_suite(manifest, name, sources, root=root) for name in manifest["suites"]}
    from test_execution import load_skip_policy, partition_default
    partitions = partition_default(manifest, sources, root=root)
    load_skip_policy(manifest, root=root, sources=sources)
    missing = set(tests) - set(selections.get("default", []))
    if missing:
        raise ValueError(f"Default suite omits application tests: {sorted(missing)}")
    windows = set(selections.get("windows", []))
    uncovered_windows = [path for path, source in sources.items() if WINDOWS_SKIP.search(source) and path not in windows]
    if uncovered_windows:
        raise ValueError(f"Windows-only cases have no Windows execution owner: {uncovered_windows}")

    entrypoints = {(entry["path"], entry["target"]): entry["reason"] for entry in manifest.get("test_entrypoints", [])}
    imports = []
    for path, source in sources.items():
        for target in IMPORT.findall(source):
            if target.startswith(("package:", "dart:")) or not target.endswith("_test.dart"):
                continue
            resolved = (root / path).parent.joinpath(target).resolve()
            try:
                rel = resolved.relative_to(root.resolve()).as_posix()
            except ValueError as error:
                raise ValueError(f"Test import escapes repository: {path}: {target}") from error
            if rel not in all_paths:
                raise ValueError(f"Missing test import: {path}: {target}")
            imports.append({"path": path, "target": rel, "entrypoint": (path, rel) in entrypoints})
    for path, target in entrypoints:
        if not any(row["path"] == path and row["target"] == target for row in imports):
            raise ValueError(f"Stale test entrypoint exception: {path}: {target}")
    if strict_imports and any(not row["entrypoint"] for row in imports):
        raise ValueError("Tests import other tests for helpers; use support files instead")

    areas: dict[str, dict[str, int]] = {}
    files = []
    for path, source in sources.items():
        parts = path.split("/")
        area = "/".join(parts[1:3] if parts[1] == "features" else parts[1:2])
        area_counts = areas.setdefault(area, {"files": 0, "lines": 0})
        lines = len(source.splitlines())
        area_counts["files"] += 1
        area_counts["lines"] += lines
        files.append({
            "path": path, "area": area, "lines": lines,
            "suites": [name for name, selected in selections.items() if path in selected],
            "windows_skip_positions": len(WINDOWS_SKIP.findall(source)),
            "widget_calls": len(re.findall(r"\btestWidgets\s*\(", source)),
            "spawns_process": bool(re.search(r"\bProcess\.(?:start|run|runSync)\s*\(", source)),
            "hardcoded_windows_release": "build/windows/x64/runner/Release" in source,
        })

    external = []
    unknown = []
    groups = manifest.get("external", [])
    group_counts: Counter[str] = Counter()
    for path in all_paths:
        if path in sources or path.startswith("build/"):
            continue
        if Path(path).suffix not in {".dart", ".py", ".rs", ".kt", ".cpp", ".swift", ".mjs", ".ps1", ".sh", ".template"}:
            continue
        source = (root / path).read_text(encoding="utf-8")
        owners = [group for group in groups if any(matches(path, pattern) for pattern in group["include"])]
        if owners and owners[0]["kind"] == "native-inline" and not is_external_test(path, source):
            continue
        if not is_external_test(path, source) and not owners:
            continue
        if not owners:
            unknown.append(path)
            continue
        if len(owners) != 1:
            raise ValueError(f"Ambiguous external test ownership: {path}")
        owner = owners[0]
        group_counts[owner["id"]] += 1
        external.append({"path": path, "owner": owner["id"], "kind": owner["kind"], "ci": owner.get("ci"), "entry": owner["entry"]})
    if unknown:
        raise ValueError(f"Unclassified external test sources: {unknown}")
    for group in groups:
        if not group_counts[group["id"]]:
            raise ValueError(f"Stale external test group: {group['id']}")

    helpers = [path for path in all_paths if path.startswith("test/") and path.endswith(".dart") and path not in sources]
    fixtures = [path for path in all_paths if path.startswith(("test/fixtures/", "packages/venera_native/test/fixtures/"))]
    return {
        "schema_version": 1,
        "application": {"files": len(files), "lines": sum(row["lines"] for row in files)},
        "areas": dict(sorted(areas.items())), "files": files,
        "suite_counts": {name: len(selected) for name, selected in selections.items()},
        "partitions": partitions,
        "test_imports": imports, "helpers": helpers, "fixtures": fixtures,
        "external": external,
        "execution_gaps": (
            [{"id": group["id"], "gap": group["gap"]} for group in groups if group.get("gap")]
            + [{"id": name, "gap": suite["gap"]} for name, suite in manifest["suites"].items() if suite.get("gap")]
        ),
        "manual_checks": [{"id": group["id"], "manual": group["manual"]} for group in groups if group.get("manual")],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--strict-imports", action="store_true")
    args = parser.parse_args()
    report = collect(strict_imports=args.strict_imports)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Test ownership: {report['application']['files']} application files; suites={report['suite_counts']}; "
          f"{len(report['external'])} external sources; {len(report['execution_gaps'])} recorded gaps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
