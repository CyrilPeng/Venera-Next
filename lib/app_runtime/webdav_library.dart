import 'dart:async';

import 'package:venera_next/features/webdav_library/webdav_library_api.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

WebDavLibraryServices? _library;
final _registryOwners = Expando<WebDavLibrarySource>('WebDAV registry owner');

/// Replace callbacks from a previous app mount with this owner's instance.
void mountWebDavLibrary(WebDavLibraryServices services) {
  if (services.source.isDisposed) return;
  _registryOwners[ComicSourceManager()] = services.source;
  _registerLibrary(
    ComicSourceManager(),
    services.source,
    services.settings.read(),
  );
}

void _registerLibrary(
  ComicSourceManager manager,
  WebDavLibrarySource source,
  WebDavLibrarySettings settings,
) {
  if (source.isDisposed) return;
  manager.remove(WebDavLibrarySource.sourceKey);
  if (settings.connection.isValid) manager.add(source.create());
}

/// Core startup and the mounted UI share this application-owned instance.
WebDavLibraryServices get webDavLibrary {
  final current = _library;
  if (current != null && !current.source.isDisposed) return current;
  return _library = createWebDavLibraryServices(
    dataPath: App.dataPath,
    manager: ComicSourceManager(),
  );
}

/// Captures the data directory and registry owner. Late forms never create a
/// replacement source or manager merely to finish a save.
WebDavLibraryServices createWebDavLibraryServices({
  required String dataPath,
  required ComicSourceManager manager,
  WebDavLibraryOps? ops,
}) {
  late WebDavLibrarySource source;
  late WebDavLibrarySettingsStore settings;
  final writer = _LibraryConfigurationWriter(
    dataPath,
    manager,
    () => source,
    () => settings.read(),
  );
  settings = WebDavLibrarySettingsStore(
    readValue: (key) => appdata.settings[key],
    persist: writer.save,
  );
  source = WebDavLibrarySource(
    readSettings: settings.read,
    cache: WebDavLibraryCache('$dataPath/webdav_library.db'),
    ops: ops,
  );
  _registryOwners[manager] = source;
  return WebDavLibraryServices(source: source, settings: settings);
}

class _LibraryConfigurationWriter {
  _LibraryConfigurationWriter(
    this.dataPath,
    this.manager,
    this.source,
    this.read,
  );

  final String dataPath;
  final ComicSourceManager manager;
  final WebDavLibrarySource Function() source;
  final WebDavLibrarySettings Function() read;
  final _invalidations = <WebDavLibraryConfig>[];
  Future<void>? _tail;

  void _checkOwner() {
    if (source().isDisposed ||
        !identical(_registryOwners[manager], source()) ||
        App.dataPath != dataPath) {
      throw StateError('WebDAV library owner changed. Reopen settings.');
    }
  }

  Future<void> save(WebDavLibrarySettings configuration) {
    // Global admission precedes the local queue, so an exclusive import cannot
    // wait on a writer that is itself blocked behind that import.
    return AppDataOperations.instance.access(() {
      _checkOwner();
      final previous = _tail;
      final done = Completer<void>();
      _tail = done.future;
      Future<void> run() async {
        try {
          if (previous != null) await previous;
          _checkOwner();
          await _save(configuration);
        } finally {
          done.complete();
          if (identical(_tail, done.future)) _tail = null;
        }
      }

      return run();
    });
  }

  Future<void> _save(WebDavLibrarySettings configuration) async {
    WebDavLibraryConfig? previous;
    final failures = <({Object error, StackTrace stackTrace})>[];
    var persisted = false;
    try {
      await appdata.updateSettings((draft) {
        _checkOwner();
        previous = WebDavLibrarySettings.read((key) => draft[key]).connection;
        for (final entry in configuration.toSettings().entries) {
          draft[entry.key] = entry.value;
        }
        final pages = List<String>.from(draft['explore_pages'] ?? <String>[]);
        pages.removeWhere(
          (page) => page == WebDavLibrarySource.explorePageTitle,
        );
        if (configuration.connection.isValid) {
          pages.add(WebDavLibrarySource.explorePageTitle);
        }
        draft['explore_pages'] = pages;
      }, sync: false);
      persisted = true;
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    // appdata can publish memory before an I/O failure. Reconcile that actual
    // state without restoring an old snapshot or reporting persistence success.
    if (previous != null &&
        !source().isDisposed &&
        identical(_registryOwners[manager], source()) &&
        App.dataPath == dataPath) {
      final current = read();
      if (previous!.connectionKey != current.connection.connectionKey) {
        _invalidations.add(previous!);
      }
      for (final pending in List.of(_invalidations)) {
        try {
          source().onConfigurationChanged(pending);
          _invalidations.remove(pending);
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
        }
      }
      try {
        _registerLibrary(manager, source(), current);
      } catch (error, stack) {
        failures.add((error: error, stackTrace: stack));
      }
    }
    if (failures.isNotEmpty) {
      throw PersistenceFailure(
        commitState: persisted
            ? PersistenceCommitState.committed
            : PersistenceCommitState.unknown,
        cause: failures.first.error,
        stackTrace: failures.first.stackTrace,
        cleanupFailures: failures.skip(1),
      );
    }
  }
}
