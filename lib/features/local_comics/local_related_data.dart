import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_api.dart';

import 'local_comic_model.dart';
import 'local_deletion_storage.dart';

/// The two cross-library operations a local library owns. SQL coordination and
/// related cache publication stay in this adapter, outside local file handling.
abstract interface class LocalComicRelatedData {
  factory LocalComicRelatedData.managed({
    LocalFavoritesManager? favorites,
    HistoryManager? history,
  }) = _ManagedLocalComicRelatedData;

  Future<void> saveMigratedHistory(History history);

  Future<void> deleteRecords({
    required Database localDatabase,
    required List<LocalComic> comics,
    required void Function() markCommitted,
    required void Function() validate,
  });
}

class _ManagedLocalComicRelatedData implements LocalComicRelatedData {
  _ManagedLocalComicRelatedData({
    LocalFavoritesManager? favorites,
    HistoryManager? history,
  }) : _favorites = favorites ?? LocalFavoritesManager(),
       _history = history ?? HistoryManager();

  final LocalFavoritesManager _favorites;
  final HistoryManager _history;

  @override
  Future<void> saveMigratedHistory(History history) =>
      _history.addHistory(history);

  @override
  Future<void> deleteRecords({
    required Database localDatabase,
    required List<LocalComic> comics,
    required void Function() markCommitted,
    required void Function() validate,
  }) async {
    final favoritesPath = _favorites.databasePath;
    final generation = _favorites.connectionGeneration;
    var removed = <String, List<(String, int)>>{};
    // Serialize with accepted reading writes; all SQL and publication finish
    // before the next history writer runs. Never adopt a reopened favorites DB.
    await _history.importStorage((historyPath) {
      validate();
      if (_favorites.databasePath != favoritesPath ||
          _favorites.connectionGeneration != generation) {
        throw StateError('Favorites storage changed during deletion');
      }
      removed = deleteLocalComicRecords(
        localDatabase: localDatabase,
        favoritesPath: favoritesPath,
        historyPath: historyPath,
        favoriteFolders: _favorites.folderNames,
        comics: comics,
        onCommit: markCommitted,
        validate: validate,
      );
    }, onCommitted: () => _favorites.refreshDeletedFavorites(removed));
  }
}
