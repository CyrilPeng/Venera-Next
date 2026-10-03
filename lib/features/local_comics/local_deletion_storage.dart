import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

import 'local_comic_model.dart';
import 'local_repository.dart';

/// One synchronous database commit. The caller serializes history writes and
/// publishes manager caches afterwards. Files are deliberately not removed here.
Map<String, List<(String, int)>> deleteLocalComicRecords({
  required Database localDatabase,
  required String favoritesPath,
  required String historyPath,
  required List<String> favoriteFolders,
  required List<LocalComic> comics,
  required void Function() onCommit,
  required void Function() validate,
}) {
  if (!localDatabase.autocommit) {
    throw StateError('Coordinated deletion requires its own transaction');
  }
  var favoritesAttached = false;
  var historyAttached = false;
  try {
    localDatabase.execute('ATTACH DATABASE ? AS deletion_favorites;', [
      favoritesPath,
    ]);
    favoritesAttached = true;
    localDatabase.execute('ATTACH DATABASE ? AS deletion_history;', [
      historyPath,
    ]);
    historyAttached = true;
    return runSqliteTransaction(localDatabase, () {
      validate();
      final identities = comics
          .map((comic) => (comic.id, comic.comicType.value))
          .toList();
      LocalRepository(localDatabase).removeAll(comics);
      final removed = FavoritesRepository(
        localDatabase,
      ).deleteComics(favoriteFolders, identities, schema: 'deletion_favorites');
      HistoryRepository(
        localDatabase,
        schema: 'deletion_history',
      ).removeMany(identities);
      onCommit();
      return removed;
    }, immediate: true);
  } finally {
    try {
      if (historyAttached) {
        localDatabase.execute('DETACH DATABASE deletion_history;');
      }
    } finally {
      if (favoritesAttached) {
        localDatabase.execute('DETACH DATABASE deletion_favorites;');
      }
    }
  }
}
