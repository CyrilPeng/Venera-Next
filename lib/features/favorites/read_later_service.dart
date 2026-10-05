import 'favorite_models.dart';
import 'favorites_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

/// SQL outcome; the owner persists the selected folder and publishes caches
/// after the transaction. Repeating a membership assignment does not move it.
class ReadLaterCommit {
  const ReadLaterCommit({
    required this.folder,
    this.created = false,
    this.added = false,
    this.removed = false,
  });
  final String? folder;
  final bool created;
  final bool added;
  final bool removed;
}

/// Read-later policy without application globals or widget dependencies.
class ReadLaterService {
  ReadLaterService({
    required this.repository,
    required this.configuredFolder,
    required this.translateTags,
  });

  final FavoritesRepository Function() repository;
  final Object? Function() configuredFolder;
  final String Function(List<String>) translateTags;

  String? get folder {
    final value = configuredFolder();
    return value is String && repository().folderNames().contains(value)
        ? value
        : null;
  }

  bool contains(String id, ComicType type) {
    final current = folder;
    return current != null && repository().comicExists(current, id, type.value);
  }

  List<FavoriteItem> comics({int? limit}) {
    final current = folder;
    return current == null
        ? []
        : repository().getFolderComics(current, limit: limit);
  }

  ReadLaterCommit set(
    FavoriteItem comic, {
    required bool included,
    required String folderName,
  }) {
    final repo = repository();
    final translated = included ? translateTags(comic.tags) : '';
    return runSqliteTransaction(repo.db, () {
      var current = folder;
      var created = false;
      if (included) {
        if (current == null) {
          if (folderName.isEmpty) {
            throw ArgumentError.value(
              folderName,
              'folderName',
              'Folder name must not be empty',
            );
          }
          var candidate = folderName;
          var suffix = 2;
          final existing = repo.folderNames().toSet();
          while (existing.contains(candidate)) {
            candidate = '$folderName (${suffix++})';
          }
          repo.createFolder(candidate);
          current = candidate;
          created = true;
        }
        final added = repo.addComic(
          current,
          comic,
          translatedTags: translated,
          append: false,
        );
        return ReadLaterCommit(folder: current, created: created, added: added);
      }
      var removed = false;
      if (current != null) {
        removed = repo
            .deleteComics([current], [(comic.id, comic.type.value)])
            .isNotEmpty;
      }
      return ReadLaterCommit(folder: current, removed: removed);
    });
  }
}
