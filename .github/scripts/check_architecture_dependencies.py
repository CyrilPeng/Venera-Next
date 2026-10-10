"""Enforce the complete library inventory and business dependency boundary.

The baseline records allowed *direct* feature edges, not individual imports.
Every library file has an explicit business, UI, or pending-review boundary.
Pending files are not assumed to be UI, but business code cannot depend on them.
UI/pending cycles are reported, while all business dependencies must be acyclic.
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


def classification_violations(graph, baseline):
    """Require a complete, disjoint inventory, including disconnected files.

    Business membership is stored, not recomputed from current reachability:
    removing an entry point cannot quietly unprotect its former dependencies.
    """
    errors = []
    roles = {}
    for name in ('business_files', 'ui_files', 'pending_review_files'):
        paths = baseline.get(name)
        if paths is None:
            errors.append(f'Missing file classification: {name}')
            continue
        if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
            errors.append(f'File classification must be a list of paths: {name}')
            continue
        seen = set()
        for path in paths:
            if path in seen:
                errors.append(f'Duplicate file classification in {name}: {path}')
                continue
            seen.add(path)
            roles.setdefault(path, []).append(name)
    for path in sorted(roles.keys() - graph.keys()):
        errors.append(f'Missing classified library file: {path}')
    for path in sorted(graph.keys() - roles.keys()):
        errors.append(f'Unclassified library file: {path}')
    for path, names in sorted(roles.items()):
        if len(names) > 1:
            errors.append(f'Conflicting file classification: {path} ({", ".join(names)})')
    protected = set(baseline.get('business_entrypoints', []))
    protected.update(baseline.get('acyclic_business_files', []))
    for path in sorted(protected):
        if roles.get(path) != ['business_files']:
            errors.append(f'Business protection requires business classification: {path}')
    return errors


def violations(graph, baseline):
    allowed = {tuple(edge) for edge in baseline["allowed_feature_edges"]}
    errors = [f"New feature dependency: {a} -> {b}"
              for a, b in sorted(feature_edges(graph) - allowed)]
    ui = set(baseline.get("ui_files", []))
    pending = set(baseline.get("pending_review_files", []))
    entrypoints = set(baseline.get("business_entrypoints", []))
    business_files = set(baseline.get("business_files", []))
    for root in sorted(entrypoints | business_files):
        label = 'Business entry point' if root in entrypoints else 'Business file'
        if root not in graph:
            if root in entrypoints:
                errors.append(f"Missing business entry point: {root}")
            continue
        dependencies = reachable(graph, root)
        business_files.update(dependencies)
        for target in sorted(dependencies & ui):
            errors.append(f"{label} reaches UI: {root} -> {target}")
        for target in sorted(dependencies & pending):
            errors.append(f"{label} reaches pending review: {root} -> {target}")
    acyclic = set(baseline.get("acyclic_business_files", []))
    for source in sorted(acyclic - graph.keys()):
        errors.append(f"Missing acyclic business file: {source}")
    acyclic.update(business_files)
    for component in cycles({(source, target) for source, targets in graph.items()
                             for target in targets}):
        if acyclic.intersection(component):
            errors.append("Business dependency cycle: " + ", ".join(component))
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
        'features/sync/data_sync_controller.dart': {'webdav', 'disableSyncFields', 'webdavSyncMode', 'webdavAutoSync', 'webdavSyncIntervalMinutes', 'webdavSyncLastAttempt', 'webdavSyncPending'},
        'app_runtime/data_sync.dart': {'webdav', 'disableSyncFields', 'webdavSyncMode', 'webdavAutoSync', 'webdavSyncIntervalMinutes', 'webdavSyncLastAttempt', 'webdavSyncPending'},
        'features/settings/webdav_settings.dart': {'backupWebdav', 'backupWebdavPath', 'backupWebdavSyncEnabled', 'webdavComicLibrary', 'webdavComicLibraryPath', 'webdavComicLibraryAutoSync', 'webdavComicLibrarySyncIntervalMinutes'},
        'features/settings/app.dart': {'webdav', 'disableSyncFields'},
        'network/app_dio.dart': {'sni', 'ignoreBadCertificate', 'dnsOverrides', 'enableDnsOverrides'},
        'network/proxy.dart': {'proxy'},
        'routing/webview.dart': {'proxy'},
        'foundation/image_provider/reader_image.dart': {'enableCustomImageProcessing', 'customImageProcessing'},
        'features/settings/reader.dart': {'enableCustomImageProcessing', 'customImageProcessing'},
        'features/local_comics/download.dart': {'downloadThreads'},
        'features/settings/network.dart': {'proxy', 'dnsOverrides', 'enableDnsOverrides', 'sni', 'downloadThreads'},
        'features/settings/appearance.dart': {'color', 'theme_mode'},
        'features/discovery/explore_page.dart': {'explore_pages'},
        'features/discovery/categories_page.dart': {'categories'},
        'features/favorites/side_bar.dart': {'favorites'},
        'features/search/search_page.dart': {'searchSources', 'defaultSearchTarget'},
        'features/search/aggregated_search_page.dart': {'searchSources'},
        'features/search/search_result_page.dart': {'searchSources', 'autoAddLanguageFilter'},
        'features/settings/explore_settings.dart': {'explore_pages', 'categories', 'favorites', 'searchSources', 'defaultSearchTarget', 'comicDisplayMode', 'comicTileScale', 'showFavoriteStatusOnTile', 'showHistoryStatusOnTile', 'showUpdateStatusOnTile', 'autoAddLanguageFilter', 'initialPage', 'comicListDisplayMode', 'reverseChapterOrder'},
        'app_shell/main_page.dart': {'initialPage'},
        'app_runtime/init.dart': {'showFavoriteStatusOnTile', 'showHistoryStatusOnTile', 'showUpdateStatusOnTile'},
        'components/layout.dart': {'comicDisplayMode', 'comicTileScale'},
        'features/comic_widgets/comic_tile.dart': {'comicDisplayMode', 'blockedWords'},
        'features/comic_widgets/comic_list.dart': {'comicListDisplayMode', 'blockedWords'},
        'features/favorites/favorite_models.dart': {'comicDisplayMode'},
        'features/settings/keyword_blocking.dart': {'blockedWords', 'blockedCommentWords'},
        'features/comic_details/comments_page.dart': {'blockedCommentWords'},
        'features/reader/chapter_comments.dart': {'blockedCommentWords'},
        'foundation/keyword_settings_store.dart': {'blockedWords', 'blockedCommentWords'},
        'features/settings/debug.dart': {'ignoreBadCertificate'},
    }
    favorite_keys = {
        'favoritesDisplayMode', 'favoritesGalleryColumns', 'localFavoritesFirst',
        'autoCloseFavoritePanel', 'newFavoriteAddTo', 'moveFavoriteAfterRead',
        'quickFavorite', 'onClickFavorite', 'readLaterFolder', 'followUpdatesFolder',
    }
    for name in (
        'app_runtime/init.dart', 'app_runtime/headless.dart',
        'app_runtime/follow_updates.dart',
        'features/favorites/favorites_display.dart',
        'features/favorites/favorites_manager.dart',
        'features/favorites/local_favorites_page.dart',
        'features/favorites/favorite_actions.dart',
        'features/settings/local_favorites.dart',
        'features/comic_details/actions.dart', 'features/comic_details/favorite.dart',
        'features/follow_updates/follow_updates_page.dart',
        'features/follow_updates/follow_updates_folder_dialog.dart',
        'features/sync/pica_import.dart',
    ):
        watched.setdefault(name, set()).update(favorite_keys)
    behavior_keys = {'language', 'checkUpdateOnStart', 'historyRetentionDays'}
    for name in (
        'main.dart', 'foundation/app_locale.dart', 'app_runtime/application_updates.dart',
        'features/settings/about.dart', 'features/settings/app.dart',
        'features/settings/app_controls.dart', 'features/history/history_manager.dart',
    ):
        watched.setdefault(name, set()).update(behavior_keys)
    literal_keys = favorite_keys | behavior_keys | {'blockedWords', 'blockedCommentWords',
                                                  'enableCustomImageProcessing', 'customImageProcessing'}
    errors = []
    pattern = re.compile(r'''\bappdata\.(?:settings|implicitData)\s*\[\s*['"]([^'"]+)['"]\s*\]''')
    form_pattern = re.compile(r'''\b(?:settingKey|settingsIndex)\s*:\s*['"]([^'"]+)['"]''')
    for name, keys in watched.items():
        source = lib / name
        if not source.exists():
            continue
        text = uncomment(source.read_text(encoding='utf-8'))
        used = set(pattern.findall(text)) | set(form_pattern.findall(text))
        if keys & literal_keys:
            # Reject raw-key aliases too. Recovery may still inspect original
            # values using the canonical Preference.key without normalizing.
            used.update(set(re.findall(r'''['"]([^'"]+)['"]''', text)) & literal_keys)
        for key in sorted(used & keys):
            errors.append(f'Use typed application preferences: {name} ({key})')
    return errors


def startup_violations(lib):
    """Core/headless startup must not activate interactive runtime bindings."""
    errors = []
    for name in ('app_runtime/bootstrap_core.dart', 'app_runtime/headless.dart',
                 'app_runtime/headless_bindings.dart'):
        source = lib / name
        if not source.exists():
            continue
        text = uncomment(source.read_text(encoding='utf-8'))
        forbidden = r'\bappNavigation\b|\bcreatePlatformInteractiveBindings\b|WindowFrame|BackgroundSync|configureComicWidgets|initializeAutoSync|Timer\.periodic|DataSync\(\)\.start\('
        if re.search(forbidden, text):
            errors.append(f'Core/headless startup activates interactive behavior: {name}')
        if name.endswith('headless.dart') and 'init.dart' in set(directives(text)):
            errors.append(f'Headless startup imports interactive initialization: {name}')
    return errors


def retired_dependency_violations(lib):
    """Do not restore global substitutions retired after consumer migration.

    Instance injection, read-only diagnostics and pure validation helpers remain
    valid. Match the retired API rather than banning every debug/test name.
    """
    retired = re.compile(
        r'\b(?:debugSkipComicSourceInit|resetForTesting|debugLoadComicImageUnwrapped|'
        r'debugResetSourceImageLoading|debugCreateDio|resetOps)\b|'
        r'\b(?:LocalManager|SourceRepositories)\s*\.\s*forTesting\b|'
        r'\b(?:HistoryManager|LocalFavoritesManager)\s*\.\s*cache\s*=(?!=)|'
        r'\bstatic\s+(?:HistoryManager|LocalFavoritesManager)\??\s+cache\s*[;=]|'
        r'\bstatic\s+set\s+cache\s*\('
    )
    backup_global = re.compile(
        r'\bstatic\s+(?!final\b|const\b)[^;{}]*?'
        r'\b(?:ops|exportComic|importComic|registerImportedComic)\s*[=;]', re.S
    )
    errors = []
    for source in sorted(lib.rglob('*.dart')):
        # Examples and explanations are not executable API declarations.
        code = TOKENS.sub(' ', source.read_text(encoding='utf-8'))
        if retired.search(code) or (
            source.relative_to(lib).as_posix() == 'features/sync/comic_backup.dart'
            and backup_global.search(code)
        ):
            errors.append(f'Retired global dependency hook: {source.relative_to(lib).as_posix()}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()
    graph = graph_for(ROOT / "lib")
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    errors = classification_violations(graph, baseline)
    # Reject malformed inventories before evaluating their dependency rules.
    if not errors:
        errors.extend(violations(graph, baseline))
    errors.extend(reader_settings_violations(ROOT / "lib"))
    errors.extend(application_settings_violations(ROOT / "lib"))
    errors.extend(startup_violations(ROOT / "lib"))
    errors.extend(retired_dependency_violations(ROOT / "lib"))
    if args.report:
        print("Feature strongly connected components (including UI):")
        for component in cycles(feature_edges(graph)):
            print("  " + ", ".join(component))
        print(f"Business entry points under enforcement: {len(baseline['business_entrypoints'])}")
        for name in ('business_files', 'ui_files', 'pending_review_files'):
            paths = baseline.get(name)
            count = len(paths) if isinstance(paths, list) else 'invalid'
            print(f"{name}: {count}")
    for error in errors:
        print(error)
    if not errors:
        print("Architecture dependency baseline is clean.")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
