import 'dart:convert';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_qjs/flutter_qjs.dart' show JSInvokable;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

import 'category.dart';
import 'comic_type_bridge.dart';
import 'favorites.dart';
import 'image_loading.dart';
import 'js_bridge.dart';
import 'parser.dart';
import 'source.dart';
import 'source_repositories.dart';

typedef RuntimeComicSourcesProvider = Iterable<ComicSource> Function();

RuntimeComicSourcesProvider? _runtimeComicSourcesProvider;

void configureRuntimeComicSourcesProvider(
  RuntimeComicSourcesProvider? provider,
) {
  _runtimeComicSourcesProvider = provider;
}

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;
  bool _closing = false;
  Future<void>? _closeFuture;
  JsEngine? _sourceEngine;
  final _pendingInitializations = <Future<void>>{};
  final _pendingDataClosures = <Future<void>>{};
  final _dataWriteFailures =
      <({String resource, Object error, StackTrace stack})>[];

  ComicSourceManager._create() {
    SourceRepositories.instance.addListener(_repositoriesChanged);
    configureComicSourceRegistry(
      all: all,
      find: find,
      fromIntKey: fromIntKey,
      isEmpty: () => isEmpty,
    );
    configureComicTypeSourceKeyResolver();
    configureCategoryDataResolver(_findCategoryDataByKey);
    configureFavoriteDataResolver(_findFavoriteDataByKey);
  }

  factory ComicSourceManager() => _instance ??= ComicSourceManager._create();

  void _repositoriesChanged() => updateAvailableUpdates({});

  void _checkAccepting() {
    if (_closing) throw StateError('Comic source manager is closing');
  }

  @override
  void notifyListeners() {
    if (!_closing) super.notifyListeners();
  }

  /// Release the notifier immediately; retain native callbacks until accepted
  /// mutations and actual init Promises (including timed-out waits) settle.
  @override
  void dispose() {
    if (_closing) return;
    _closing = true;
    SourceRepositories.instance.removeListener(_repositoriesChanged);
    super.dispose();
    _closeFuture = _closeResources();
    unawaited(
      _closeFuture!.catchError((Object error, StackTrace stack) {
        Log.error('ComicSource close', error, stack);
      }),
    );
  }

  Future<void> closeAndWait() {
    dispose();
    return _closeFuture!;
  }

  @override
  Future<void> init() {
    if (_closing) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    return super.init();
  }

  @override
  Future<void> ensureInit() {
    if (_closing) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    return super.ensureInit();
  }

  Future<void> _closeResources() async {
    await _mutationTail;
    while (_pendingInitializations.isNotEmpty) {
      await Future.wait(_pendingInitializations.toList());
    }
    for (final source in _sources) {
      _retireSourceDataWrites(source);
    }
    while (_pendingDataClosures.isNotEmpty) {
      await Future.wait(_pendingDataClosures.toList());
    }
    final failures = List.of(_dataWriteFailures);
    _dataWriteFailures.clear();
    for (final source in _sources) {
      try {
        if (source.filePath.isNotEmpty) {
          _sourceEngine?.runCode(
            'delete ComicSource.sources[${jsonEncode(source.key)}];',
          );
        }
      } catch (error, stack) {
        failures.add((
          resource: '${source.key} registry',
          error: error,
          stack: stack,
        ));
      }
      try {
        source.disposeRuntimeCallbacks();
      } catch (error, stack) {
        failures.add((
          resource: '${source.key} callbacks',
          error: error,
          stack: stack,
        ));
      }
    }
    _sources.clear();
    _availableUpdates.clear();
    _sourceEngine = null;
    if (identical(_instance, this)) {
      _instance = null;
      configureComicSourceRegistry(
        all: () => [],
        find: (_) => null,
        fromIntKey: (_) => null,
        isEmpty: () => true,
      );
      configureCategoryDataResolver(null);
      configureFavoriteDataResolver(null);
      configureComicSourceImageDownloader(
        thumbnailLoadingConfig: (_, _) => {},
        thumbnailCover: (_, _) async => null,
        comicImageLoadingConfig: (_, _, _, _) async => {},
      );
    }
    if (failures.isNotEmpty) throw JsResourceReleaseFailure(failures);
  }

  // Replaced and removed sources can still own accepted file writes even after
  // leaving the registry. Keep their completion and failures in this host.
  void _retireSourceDataWrites(ComicSource source) {
    late final Future<void> settled;
    settled = Future<void>.sync(source.closeDataWrites)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _dataWriteFailures.add((
              resource: '${source.key} data',
              error: error,
              stack: stack,
            ));
          },
        )
        .whenComplete(() => _pendingDataClosures.remove(settled));
    _pendingDataClosures.add(settled);
  }

  List<ComicSource> all() => List.from(_sources);

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key);

  CategoryData _findCategoryDataByKey(String key) {
    for (var source in all()) {
      if (source.categoryData?.key == key) {
        return source.categoryData!;
      }
    }
    throw "Unknown category key $key";
  }

  FavoriteData? _findFavoriteDataByKey(String key) {
    return find(key)?.favoriteData;
  }

  @override
  @protected
  // Initial loading mutates the same Dart/JS registries as reload and install.
  // Keep it inside their queue so no later mutation can replace staged state.
  Future<void> doInit() => _mutate(_loadSources);

  Future<void> _loadSources({
    Set<String> existingFiles = const {},
    Set<ComicSource> preservedSources = const {},
  }) async {
    await SourceRepositories.instance.migrate();
    configureComicTypeSourceKeyResolver();
    configureComicSourceImageDownloader(
      thumbnailLoadingConfig: _getThumbnailLoadingConfig,
      thumbnailCover: _getThumbnailCover,
      comicImageLoadingConfig: _getComicImageLoadingConfig,
    );
    configureComicSourceJsDataBridge();
    await JsEngine().ensureInit();
    final loaded = <ComicSource>[];
    final parsers = <ComicSourceParser>[];
    final addedRuntime = <ComicSource>[];
    try {
      final path = "${App.dataPath}/comic_source";
      if (!(await Directory(path).exists())) {
        await Directory(path).create();
      } else {
        await for (var entity in Directory(path).list()) {
          if (entity is File && entity.path.endsWith(".js")) {
            try {
              final parser = ComicSourceParser();
              final source = await parser.parse(
                await entity.readAsString(),
                entity.absolute.path,
                retainRollback: true,
              );
              parsers.add(parser);
              _sources.add(source);
              loaded.add(source);
            } catch (e, s) {
              if (existingFiles.contains(entity.absolute.path)) rethrow;
              Log.error("ComicSource", "$e\n$s");
            }
          }
        }
      }
      final runtimeSources =
          _runtimeComicSourcesProvider?.call() ?? const <ComicSource>[];
      for (final source in runtimeSources) {
        if (find(source.key) == null) {
          _sources.add(source);
          addedRuntime.add(source);
        }
      }
    } catch (_) {
      // Only remove this attempt's registrations. Parser rollback restores the
      // previous JS slot and frees the callbacks belonging to each loaded file.
      final staged = Set<ComicSource>.identity()
        ..addAll(loaded)
        ..addAll(addedRuntime);
      _sources.removeWhere(staged.contains);
      for (final parser in parsers.reversed) {
        try {
          parser.rollback();
        } catch (error, stack) {
          Log.error('ComicSource rollback', error, stack);
        }
      }
      for (final source in addedRuntime) {
        if (!preservedSources.contains(source)) {
          source.disposeRuntimeCallbacks();
        }
      }
      rethrow;
    }
    for (final parser in parsers) {
      parser.commit();
    }
    // Register every source before invoking init. Network work in one source
    // must not hold up startup or prevent the other sources from initializing.
    for (final source in loaded) {
      unawaited(
        _initializeSource(source).catchError((Object error, StackTrace stack) {
          Log.error('ComicSource', '${source.name}: $error', stack);
        }),
      );
    }
  }

  Future<void> _mutationTail = Future.value();

  Future<T> _mutate<T>(Future<T> Function() action) {
    if (_closing) {
      return Future.error(StateError('Comic source manager is closing'));
    }
    final result = _mutationTail.then((_) {
      _sourceEngine = JsEngine();
      return action();
    });
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> reload() => _mutate(_reloadSources);

  Future<void> _reloadSources() async {
    final previous = List<ComicSource>.of(_sources);
    final preserved = Set<ComicSource>.identity()..addAll(previous);
    final engine = JsEngine();
    final restore =
        engine.runCode('''(() => {
      const previous = ComicSource.sources;
      ComicSource.sources = {};
      return () => { ComicSource.sources = previous; };
    })()''')
            as JSInvokable;
    _sources.clear();
    try {
      await _loadSources(
        existingFiles: previous
            .where((source) => source.filePath.isNotEmpty)
            .map((source) => File(source.filePath).absolute.path)
            .toSet(),
        preservedSources: preserved,
      );
    } catch (_) {
      _sources
        ..clear()
        ..addAll(previous);
      restore.invoke([]);
      rethrow;
    } finally {
      restore.free();
    }
    final current = Set<ComicSource>.identity()..addAll(_sources);
    for (final source in previous) {
      if (!current.contains(source)) {
        _retireSourceDataWrites(source);
        source.disposeRuntimeCallbacks();
      }
    }
    notifyListeners();
  }

  Future<void> reloadForDebug() => _mutate(() async {
    final errors = <String>[];
    for (final source in all().where((source) => source.filePath.isNotEmpty)) {
      try {
        await _replaceScript(
          source,
          await File(source.filePath).readAsString(),
          validate: () {},
        );
      } catch (error) {
        errors.add('${source.name}: $error');
      }
    }
    notifyListeners();
    if (errors.isNotEmpty) throw ComicSourceParseException(errors.join('\n'));
  });

  Future<void> _initializeSource(ComicSource source) async {
    final running = Future<void>.sync(
      () => JsEngine().runCode('''(() => {
        const result = ComicSource.sources[${jsonEncode(source.key)}]?.init?.();
        return result && typeof result.then === 'function'
          ? result.then(() => undefined) : undefined;
      })()''', source.filePath),
    );
    late final Future<void> settled;
    settled = running
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pendingInitializations.remove(settled));
    _pendingInitializations.add(settled);
    await running.timeout(const Duration(seconds: 15));
  }

  Map<String, dynamic> _snapshotPages() => {
    for (final key in [
      'explore_pages',
      'categories',
      'favorites',
      'searchSources',
    ])
      key: appdata.settings[key] == null
          ? null
          : List.from(appdata.settings[key]),
  };

  void _restorePages(Map<String, dynamic> pages) {
    for (final entry in pages.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  }

  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) => _mutate(() async {
    beforeInstall();
    final oldPages = _snapshotPages();
    ComicSource? source;
    SourceOrigin? oldOrigin;
    final parser = ComicSourceParser();
    try {
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_.()-]'), '_');
      source = await parser.createAndParse(
        js,
        fileName,
        expectedKey: expectedKey,
        retainRollback: true,
      );
      oldOrigin = SourceRepositories.instance.originFor(source.key);
      _sources.add(source);
      source.stageDataWrites();
      await _initializeSource(source);
      _registerSourcePages(source);
      await SourceRepositories.instance.setOrigin(source.key, origin);
      await source.commitDataWrites();
      parser.commit();
      notifyListeners();
      return source;
    } catch (_) {
      parser.rollback();
      if (source != null) {
        _sources.removeWhere((s) => s.key == source!.key);
        JsEngine().runCode(
          'delete ComicSource.sources[${jsonEncode(source.key)}];',
        );
        await File(source.filePath).deleteIfExists();
        _restorePages(oldPages);
        await SourceRepositories.instance.setOrigin(source.key, oldOrigin);
      }
      notifyListeners();
      rethrow;
    }
  });

  Future<void> replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) => _mutate(
    () => _replaceScript(source, js, validate: validate, origin: origin),
  );

  Future<void> _replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) async {
    validate();
    final index = _sources.indexWhere((item) => item.key == source.key);
    if (index < 0 || _sources[index].filePath != source.filePath) {
      throw ComicSourceParseException('The source is no longer installed.');
    }
    source = _sources[index];
    final parser = ComicSourceParser();
    final originalScript = await File(source.filePath).readAsString();
    final oldPages = _snapshotPages();
    final oldOrigin = SourceRepositories.instance.originFor(source.key);
    var changedSettings = false;
    var wroteScript = false;
    try {
      final replacement = await parser.parse(
        js,
        source.filePath,
        expectedKey: source.key,
        replacing: true,
        retainRollback: true,
      );
      replacement.data = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(source.data)),
      );
      replacement.stageDataWrites();
      _sources[index] = replacement;
      await _initializeSource(replacement);
      final temporary = File('${source.filePath}.update');
      try {
        await temporary.writeAsString(js, flush: true);
        await temporary.rename(source.filePath);
        wroteScript = true;
      } finally {
        await temporary.deleteIfExists();
      }
      _registerSourcePages(replacement);
      changedSettings = true;
      if (origin != null) {
        await SourceRepositories.instance.setOrigin(source.key, origin);
      } else {
        await appdata.saveData();
      }
      await replacement.commitDataWrites();
      parser.commit();
      _retireSourceDataWrites(source);
      source.disposeRuntimeCallbacks();
      clearSourceUpdate(source.key);
      notifyListeners();
    } catch (_) {
      _sources[index] = source;
      parser.rollback();
      if (wroteScript) {
        await File(source.filePath).writeAsString(originalScript, flush: true);
      }
      _restorePages(oldPages);
      if (changedSettings) {
        if (origin != null) {
          await SourceRepositories.instance.setOrigin(source.key, oldOrigin);
        } else {
          await appdata.saveData(false);
        }
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> uninstallScript(ComicSource source) => _mutate(() async {
    await File(source.filePath).deleteIfExists();
    _remove(source.key);
    JsEngine().runCode(
      'delete ComicSource.sources[${jsonEncode(source.key)}];',
    );
    await SourceRepositories.instance.setOrigin(source.key, null);
  });

  void add(ComicSource source) {
    _checkAccepting();
    _sourceEngine = JsEngine();
    _sources.add(source);
    notifyListeners();
  }

  void remove(String key) {
    _checkAccepting();
    _remove(key);
  }

  void _remove(String key) {
    for (final source in _sources.where((source) => source.key == key)) {
      _retireSourceDataWrites(source);
      source.disposeRuntimeCallbacks();
    }
    _sources.removeWhere((element) => element.key == key);
    notifyListeners();
  }

  void _registerSourcePages(ComicSource source) {
    var explorePages = appdata.settings['explore_pages'] ?? <String>[];
    var categoryPages = appdata.settings['categories'] ?? <String>[];
    var networkFavorites = appdata.settings['favorites'] ?? <String>[];
    var searchPages = appdata.settings['searchSources'] ?? <String>[];

    if (source.explorePages.isNotEmpty) {
      for (var page in source.explorePages) {
        if (!explorePages.contains(page.title)) {
          explorePages.add(page.title);
        }
      }
    }
    if (source.categoryData != null &&
        !categoryPages.contains(source.categoryData!.key)) {
      categoryPages.add(source.categoryData!.key);
    }
    if (source.favoriteData != null &&
        !networkFavorites.contains(source.favoriteData!.key)) {
      networkFavorites.add(source.favoriteData!.key);
    }
    if (source.searchPageData != null && !searchPages.contains(source.key)) {
      searchPages.add(source.key);
    }

    appdata.settings['explore_pages'] = explorePages.toSet().toList();
    appdata.settings['categories'] = categoryPages.toSet().toList();
    appdata.settings['favorites'] = networkFavorites.toSet().toList();
    appdata.settings['searchSources'] = searchPages.toSet().toList();
  }

  bool get isEmpty => _sources.isEmpty;

  FutureOr<Map<String, dynamic>> _getThumbnailLoadingConfig(
    String sourceKey,
    String url,
  ) {
    final comicSource = find(sourceKey);
    return comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
  }

  Future<String?> _getThumbnailCover(String sourceKey, String cid) async {
    final comicSource = find(sourceKey);
    if (comicSource?.loadComicInfo == null) {
      return null;
    }
    final comicInfo = await comicSource!.loadComicInfo!(cid);
    return comicInfo.data.cover;
  }

  Future<Map<String, dynamic>> _getComicImageLoadingConfig(
    String sourceKey,
    String imageKey,
    String cid,
    String eid,
  ) async {
    final comicSource = find(sourceKey);
    return await comicSource?.getImageLoadingConfig?.call(imageKey, cid, eid) ??
        {};
  }

  /// Key is the source key, value is the version.
  final _availableUpdates = <String, String>{};

  void updateAvailableUpdates(Map<String, String> updates) {
    _checkAccepting();
    _availableUpdates.clear();
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void clearSourceUpdate(String key) {
    _checkAccepting();
    _availableUpdates.remove(key);
    notifyListeners();
  }

  void notifyStateChange() {
    notifyListeners();
  }
}
