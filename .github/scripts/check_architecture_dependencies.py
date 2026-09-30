"""Reject new feature dependencies and UI reachable from business entry points.

The baseline records allowed *direct* feature edges, not individual imports.
Existing UI cycles are reported, not mistaken for business-layer cycles.
Business entry points are opt-in in the baseline as domains are migrated.
"""

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "doc/architecture/dependency_baseline.json"
TOKENS = re.compile(
    r'''r?"""[\s\S]*?"""|r?''' + "'''[\\s\\S]*?'''" +
    r'''|r?"(?:\\.|[^"\\])*"|r?'(?:\\.|[^'\\])*'|/\*[\s\S]*?\*/|//[^\n]*'''
)
DIRECTIVE = re.compile(r"\b(?:import|export|part)\s+(?!of\b)([^;]+);", re.S)
SCAN = re.compile(r"(?P<directive>" + DIRECTIVE.pattern + r")|" + TOKENS.pattern, re.S)
STRINGS = re.compile(r'''['"]([^'"\n]+)['"]''')


def uncomment(text):
    return TOKENS.sub(
        lambda m: " " if m[0].startswith(("//", "/*")) else m[0], text
    )


def directives(text):
    """Include all alternatives of conditional imports/exports and part files."""
    for token in SCAN.finditer(uncomment(text)):
        if token.group("directive") is not None:
            yield from STRINGS.findall(token.group("directive"))


def graph_for(lib):
    lib = lib.resolve()
    files = {p.resolve() for p in lib.rglob("*.dart")}
    graph = {}
    for source in sorted(files):
        edges = set()
        for uri in directives(source.read_text(encoding="utf-8")):
            if uri.startswith("package:venera_next/"):
                target = lib / uri[len("package:venera_next/"):]
            elif ":" not in uri:
                target = source.parent / uri
            else:
                continue
            target = target.resolve()
            if target in files:
                edges.add(target.relative_to(lib).as_posix())
        graph[source.relative_to(lib).as_posix()] = edges
    return graph


def feature(path):
    parts = path.split("/")
    return parts[1] if len(parts) > 2 and parts[0] == "features" else None


def feature_edges(graph):
    return {
        (feature(source), feature(target))
        for source, targets in graph.items()
        for target in targets
        if feature(source) and feature(target) and feature(source) != feature(target)
    }


def cycles(edges):
    """Tarjan strongly connected components, with deterministic report order."""
    graph = {}
    for a, b in edges:
        graph.setdefault(a, set()).add(b)
        graph.setdefault(b, set())
    indices, low, stack, active, result = {}, {}, [], set(), []

    def visit(node):
        indices[node] = low[node] = len(indices)
        stack.append(node)
        active.add(node)
        for child in sorted(graph[node]):
            if child not in indices:
                visit(child)
                low[node] = min(low[node], low[child])
            elif child in active:
                low[node] = min(low[node], indices[child])
        if low[node] == indices[node]:
            component = []
            while True:
                child = stack.pop()
                active.remove(child)
                component.append(child)
                if child == node:
                    break
            if len(component) > 1 or node in graph[node]:
                result.append(sorted(component))

    for node in sorted(graph):
        if node not in indices:
            visit(node)
    return sorted(result)


def reachable(graph, root):
    seen, pending = set(), [root]
    while pending:
        node = pending.pop()
        if node in seen:
            continue
        seen.add(node)
        pending.extend(graph.get(node, ()))
    return seen


def violations(graph, baseline):
    allowed = {tuple(edge) for edge in baseline["allowed_feature_edges"]}
    errors = [f"New feature dependency: {a} -> {b}"
              for a, b in sorted(feature_edges(graph) - allowed)]
    ui = set(baseline.get("ui_files", []))
    for root in baseline.get("business_entrypoints", []):
        if root not in graph:
            errors.append(f"Missing business entry point: {root}")
            continue
        for target in sorted(reachable(graph, root) & ui):
            errors.append(f"Business entry point reaches UI: {root} -> {target}")
    return errors


def reader_settings_violations(lib):
    """Keep migrated reader code on the typed preference boundary."""
    errors = []
    sources = set((lib / "features/reader").rglob("*.dart"))
    sources.update(
        source for name in ("reader.dart", "reader_mode.dart")
        if (source := lib / "features/settings" / name).exists()
    )
    for source in sorted(sources):
        text = uncomment(source.read_text(encoding="utf-8"))
        if re.search(r"\b(?:getReaderSetting|getDeviceReaderSetting|setActiveReaderSetting)\s*\(", text):
            errors.append(f"Reader must use typed settings: {source.relative_to(lib).as_posix()}")
    return errors


def application_settings_violations(lib):
    watched = {
        'main.dart': {'color', 'theme_mode'},
        'features/sync/data_sync.dart': {'webdav', 'disableSyncFields', 'webdavSyncMode', 'webdavAutoSync', 'webdavSyncIntervalMinutes', 'webdavSyncLastAttempt', 'webdavSyncPending'},
        'features/settings/app.dart': {'webdav', 'disableSyncFields'},
        'network/app_dio.dart': {'sni', 'ignoreBadCertificate', 'dnsOverrides', 'enableDnsOverrides'},
        'network/proxy.dart': {'proxy'},
        'features/local_comics/download.dart': {'downloadThreads'},
        'features/settings/network.dart': {'proxy', 'dnsOverrides', 'enableDnsOverrides', 'sni', 'downloadThreads'},
        'features/settings/appearance.dart': {'color', 'theme_mode'},
    }
    errors = []
    pattern = re.compile(r'''\bappdata\.(?:settings|implicitData)\s*\[\s*['"]([^'"]+)['"]\s*\]''')
    for name, keys in watched.items():
        source = lib / name
        if not source.exists():
            continue
        used = set(pattern.findall(uncomment(source.read_text(encoding='utf-8'))))
        for key in sorted(used & keys):
            errors.append(f'Use typed application preferences: {name} ({key})')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()
    graph = graph_for(ROOT / "lib")
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    errors = violations(graph, baseline)
    errors.extend(reader_settings_violations(ROOT / "lib"))
    errors.extend(application_settings_violations(ROOT / "lib"))
    if args.report:
        print("Feature strongly connected components (including UI):")
        for component in cycles(feature_edges(graph)):
            print("  " + ", ".join(component))
        print(f"Business entry points under enforcement: {len(baseline['business_entrypoints'])}")
    for error in errors:
        print(error)
    if not errors:
        print("Architecture dependency baseline is clean.")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
