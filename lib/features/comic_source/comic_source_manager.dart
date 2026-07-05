import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/app.dart';
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
    configureComicTypeSourceKeyResolver();
    configureComicSourceImageDownloader(
      thumbnailLoadingConfig: _getThumbnailLoadingConfig,
      thumbnailCover: _getThumbnailCover,
      comicImageLoadingConfig: _getComicImageLoadingConfig,
    );
    configureComicSourceJsDataBridge();
    await JsEngine().ensureInit();
    final path = "${App.dataPath}/comic_source";
    if (!(await Directory(path).exists())) {
      Directory(path).create();
      return;
    }
    await for (var entity in Directory(path).list()) {
      if (entity is File && entity.path.endsWith(".js")) {
        try {
          var source = await ComicSourceParser().parse(
            await entity.readAsString(),
            entity.absolute.path,
          );
          _sources.add(source);
        } catch (e, s) {
          Log.error("ComicSource", "$e\n$s");
        }
      }
    }
  }

  Future reload() async {
    _sources.clear();
    JsEngine().runCode("ComicSource.sources = {};");
    await doInit();
    notifyListeners();
  }

  void add(ComicSource source) {
    _sources.add(source);
    notifyListeners();
  }

  void remove(String key) {
    _sources.removeWhere((element) => element.key == key);
    notifyListeners();
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
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void notifyStateChange() {
    notifyListeners();
  }
}
