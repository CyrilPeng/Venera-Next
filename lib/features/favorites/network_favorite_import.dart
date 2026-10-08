import 'dart:math' as math;
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:venera_next/network/request_scope.dart';
import 'favorite_models.dart';
import 'favorites_repository.dart';

typedef FavoriteImportProgress = ({int pages, int received, int collected});

/// Durable SQL result. Publishing this result never repeats the import.
class NetworkFavoriteImportCommit {
  NetworkFavoriteImportCommit(
    this.folder,
    Iterable<FavoriteItem> added, {
    this.owner,
    this.generation,
  }) : identities = List.unmodifiable(
         added.map((item) => (item.id, item.type.value)),
       );

  final String folder;
  final Object? owner;
  final int? generation;
  final List<(String, int)> identities;
  int get count => identities.length;
}

Future<List<FavoriteItem>> collectNetworkFavorites({
  required FavoriteData data,
  required String sourceKey,
  required String? folderId,
  required int pageLimit,
  required RequestScope scope,
  required bool Function(String id) exists,
  required void Function(FavoriteImportProgress) onProgress,
  bool Function()? isCurrent,
}) async {
  if (pageLimit <= 0) return [];
  void checkActive() {
    scope.check();
    if (isCurrent?.call() == false) throw const RequestCancelled();
  }

  Future<Res<T>> request<T>(Future<Res<T>> Function() load) async {
    for (var attempt = 0; ; attempt++) {
      checkActive();
      try {
        return await scope.runToCompletion(() async {
          final result = await load();
          if (result.error) {
            final failure = result.failure;
            if (failure != null) {
              Error.throwWithStackTrace(
                failure,
                failure.stackTrace ?? StackTrace.current,
              );
            }
            throw StateError(result.errorMessage!);
          }
          return result;
        });
      } catch (error) {
        if (scope.isCancelled ||
            isCurrent?.call() == false ||
            error is RequestCancelled ||
            error is UnsupportedError ||
            error is FailureDetails && error.kind != FailureKind.failed ||
            attempt == 2) {
          rethrow;
        }
      }
    }
  }

  var page = 1;
  var pages = 0;
  var received = 0;
  String? cursor;
  final seenCursors = <String>{};
  final seenIds = <String>{};
  final items = <FavoriteItem>[];
  if (data.loadComic != null && data.isOldToNewSort == true) {
    final first = await request(() => data.loadComic!(1, folderId));
    final total = first.subData;
    if (total != null && (total is! int || total < 1)) {
      throw const FormatException('Invalid favorite page count');
    }
    page = math.max(1, (total as int? ?? 1) - pageLimit + 1);
  }
  while (pages < pageLimit) {
    checkActive();
    final Res<List<Comic>> result;
    if (data.loadComic != null) {
      result = await request(() => data.loadComic!(page, folderId));
    } else if (data.loadNext != null) {
      result = await request(() => data.loadNext!(cursor, folderId));
    } else {
      throw UnsupportedError('Source has no favorite loader');
    }
    checkActive();
    final batch = result.data;
    received += batch.length;
    for (final comic in batch) {
      if (seenIds.add(comic.id) && !exists(comic.id)) {
        items.add(
          FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: comic.cover,
            type: ComicType(sourceKey.hashCode),
            author: comic.subtitle ?? '',
            tags: List.of(comic.tags ?? []),
          ),
        );
      }
    }
    pages++;
    onProgress((pages: pages, received: received, collected: items.length));
    if (batch.isEmpty) break;
    if (data.loadComic != null) {
      final total = result.subData;
      if (total != null && (total is! int || total < 1)) {
        throw const FormatException('Invalid favorite page count');
      }
      if (total is int && page >= total) break;
      page++;
    } else {
      final next = result.subData;
      if (next == null) break;
      if (next is! String || !seenCursors.add(next)) {
        throw const FormatException('Invalid or repeated favorite cursor');
      }
      cursor = next;
    }
  }
  checkActive();
  return items;
}

List<FavoriteItem> commitNetworkFavorites(
  FavoritesRepository repository, {
  required String folder,
  required String source,
  required String folderId,
  required List<FavoriteItem> items,
  required bool append,
  required bool oldToNew,
  required String Function(List<String>) translateTags,
}) {
  if (folder.isEmpty) {
    throw ArgumentError.value(folder, 'folder', 'Empty folder name');
  }
  final ordered = !append && !oldToNew ? items.reversed.toList() : items;
  final translated = ordered.map((item) => translateTags(item.tags)).toList();
  return runSqliteTransaction(repository.db, () {
    if (repository.folderNames().contains(folder)) {
      if (!repository.isLinkedToNetworkFolder(folder, source, folderId)) {
        throw StateError('Folder already exists');
      }
    } else {
      repository.createFolder(folder);
      repository.linkFolderToNetwork(folder, source, folderId);
    }
    final added = <FavoriteItem>[];
    for (var i = 0; i < ordered.length; i++) {
      if (repository.addComic(
        folder,
        ordered[i],
        translatedTags: translated[i],
        append: append,
      )) {
        added.add(ordered[i]);
      }
    }
    return added;
  });
}
