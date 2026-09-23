import 'dart:convert';
import 'dart:async';

import 'package:flutter/widgets.dart';
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
import 'models.dart';
import 'normalization.dart';
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

@visibleForTesting
Map<String, Map<String, dynamic>>? debugNormalizeComicSourceSettings(
  dynamic value,
) {
  return normalizeComicSourceSettings(value);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceLoadingConfig(dynamic value) {
  return normalizeComicSourceLoadingConfig(value);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceStringKeyedMap(dynamic value) {
  return normalizeComicSourceStringKeyedMap(value);
}

@visibleForTesting
List<String>? debugNormalizeComicSourceStringList(dynamic value) {
  return normalizeComicSourceStringList(value);
}

@visibleForTesting
List<Comic>? debugNormalizeComicSourceComicList(
  dynamic value,
  String sourceKey,
) {
  return normalizeComicSourceComicList(value, sourceKey);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceComicDetails(
  dynamic value,
  String sourceKey,
  String comicId,
) {
  return normalizeComicSourceComicDetails(value, sourceKey, comicId);
}

@visibleForTesting
({Map<String, dynamic> data, List<Comment> comments})?
debugNormalizeComicSourceCommentsResult(dynamic value) {
  return normalizeComicSourceCommentsResult(value);
}

@visibleForTesting
List<ArchiveInfo>? debugNormalizeComicSourceArchiveList(dynamic value) {
  return normalizeComicSourceArchiveList(value);
}

@visibleForTesting
String? debugNormalizeComicSourceArchiveDownloadUrl(dynamic value) {
  return normalizeComicSourceArchiveDownloadUrl(value);
}

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;

  ComicSourceManager._create() {
    SourceRepositories.instance.addListener(() => updateAvailableUpdates({}));
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
  Future<void> doInit() async {
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
    final path = "${App.dataPath}/comic_source";
    if (!(await Directory(path).exists())) {
      await Directory(path).create();
    } else {
      await for (var entity in Directory(path).list()) {
        if (entity is File && entity.path.endsWith(".js")) {
          try {
            var source = await ComicSourceParser().parse(
              await entity.readAsString(),
              entity.absolute.path,
            );
            _sources.add(source);
            loaded.add(source);
          } catch (e, s) {
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
      }
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
    final result = _mutationTail.then((_) => action());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> reload() => _mutate(_reloadSources);

  Future<void> _reloadSources() async {
    _sources.clear();
    JsEngine().runCode('ComicSource.sources = {};');
    await doInit();
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

  Future<void> reloadSource(ComicSource source) => _mutate(() async {
    await _replaceScript(
      source,
      await File(source.filePath).readAsString(),
      validate: () {},
    );
  });

  Future<void> _initializeSource(ComicSource source) async {
    await Future.sync(
      () => JsEngine().runCode('''(() => {
        const result = ComicSource.sources[${jsonEncode(source.key)}]?.init?.();
        return result && typeof result.then === 'function'
          ? result.then(() => undefined) : undefined;
      })()''', source.filePath),
    ).timeout(const Duration(seconds: 15));
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
    remove(source.key);
    JsEngine().runCode(
      'delete ComicSource.sources[${jsonEncode(source.key)}];',
    );
    await SourceRepositories.instance.setOrigin(source.key, null);
  });

  void add(ComicSource source) {
    _sources.add(source);
    notifyListeners();
  }

  void remove(String key) {
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

  Map<String, dynamic> _getThumbnailLoadingConfig(
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
    _availableUpdates.clear();
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void clearSourceUpdate(String key) {
    _availableUpdates.remove(key);
    notifyListeners();
  }

  void notifyStateChange() {
    notifyListeners();
  }
}
