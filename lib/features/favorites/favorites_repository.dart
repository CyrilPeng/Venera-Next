import 'package:sqlite3/sqlite3.dart';
import 'favorite_models.dart';
import 'favorite_row.dart';

/// Favorite persistence on a caller-owned connection; no cache or notifications.
class FavoritesRepository {
  FavoritesRepository(this.db);
  final Database db;

  T _transaction<T>(T Function() action) {
    db.execute('BEGIN TRANSACTION;');
    try {
      final result = action();
      db.execute('COMMIT;');
      return result;
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _copyRecord(
    String source,
    String target,
    String id,
    int type,
    int order, {
    required bool ignoreExisting,
  }) {
    db.execute(
      '''
      INSERT ${ignoreExisting ? 'OR IGNORE ' : ''}INTO ${_table(target)}
        (id, name, author, type, tags, cover_path, time, display_order)
      SELECT id, name, author, type, tags, cover_path, time, ?
      FROM ${_table(source)} WHERE id = ? AND type = ?;
    ''',
      [order, id, type],
    );
  }

  void _removeRecord(String folder, String id, int type) {
    db.execute('DELETE FROM ${_table(folder)} WHERE id = ? AND type = ?;', [
      id,
      type,
    ]);
  }

  /// Single moves leave the source intact when the destination already exists.
  bool moveFavorite(String source, String target, String id, int type) =>
      _transaction(() {
        if (comicExists(target, id, type)) return false;
        _copyRecord(
          source,
          target,
          id,
          type,
          minValue(target) - 1,
          ignoreExisting: false,
        );
        _removeRecord(source, id, type);
        return true;
      });

  void moveMany(
    String source,
    String target,
    Iterable<(String, int)> identities,
  ) => _transferMany(source, target, identities, removeSource: true);

  void copyMany(
    String source,
    String target,
    Iterable<(String, int)> identities,
  ) => _transferMany(source, target, identities, removeSource: false);

  void _transferMany(
    String source,
    String target,
    Iterable<(String, int)> identities, {
    required bool removeSource,
  }) {
    if (source == target) return;
    _transaction(() {
      var order = maxValue(target) + 1;
      for (final (id, type) in identities) {
        _copyRecord(source, target, id, type, order, ignoreExisting: true);
        // Batch moves preserve the existing merge policy: keep destination
        // metadata on conflicts and remove the matching source record.
        if (removeSource) _removeRecord(source, id, type);
        order++;
      }
    });
  }

  static String _table(String folder) => '"${folder.replaceAll('"', '""')}"';

  List<String> folderNames() {
    final folders =
        db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((row) => row['name'] as String)
            .toList()
          ..remove('folder_sync')
          ..remove('folder_order');
    final knownFolders = folders.toSet();
    final orders = <String, int>{};
    for (final row in db.select(
      'SELECT folder_name, order_value FROM folder_order;',
    )) {
      final name = row['folder_name'];
      if (name is String && knownFolders.contains(name)) {
        orders.putIfAbsent(name, () => row['order_value'] as int);
      }
    }
    folders.sort((a, b) => (orders[a] ?? 0) - (orders[b] ?? 0));
    return folders;
  }

  int count(String folder) =>
      db.select('SELECT COUNT(*) AS c FROM ${_table(folder)};').first['c']
          as int;

  int maxValue(String folder) =>
      db
              .select(
                'SELECT MAX(display_order) AS value FROM ${_table(folder)};',
              )
              .first['value']
          as int? ??
      0;

  int minValue(String folder) =>
      db
              .select(
                'SELECT MIN(display_order) AS value FROM ${_table(folder)};',
              )
              .first['value']
          as int? ??
      0;

  List<FavoriteItem> getFolderComics(String folder) => db
      .select('SELECT * FROM ${_table(folder)} ORDER BY display_order;')
      .map(favoriteItemFromRow)
      .toList();

  List<FavoriteItem> getAllComics(Iterable<String> folders) {
    final result = <FavoriteItem>{};
    for (final folder in folders) {
      result.addAll(
        db.select('SELECT * FROM ${_table(folder)};').map(favoriteItemFromRow),
      );
    }
    return result.toList();
  }

  List<FavoriteItemWithFolderInfo> allComics(Iterable<String> folders) => [
    for (final folder in folders)
      for (final row in db.select('SELECT * FROM ${_table(folder)};'))
        FavoriteItemWithFolderInfo(favoriteItemFromRow(row), folder),
  ];

  bool comicExists(String folder, String id, int type) => db.select(
    'SELECT 1 FROM ${_table(folder)} WHERE id = ? AND type = ? LIMIT 1;',
    [id, type],
  ).isNotEmpty;

  FavoriteItem? findComic(String folder, String id, int type) {
    final rows = db.select(
      'SELECT * FROM ${_table(folder)} WHERE id = ? AND type = ?;',
      [id, type],
    );
    return rows.isEmpty ? null : favoriteItemFromRow(rows.first);
  }

  List<String> findFolders(Iterable<String> folders, String id, int type) => [
    for (final folder in folders)
      if (comicExists(folder, id, type)) folder,
  ];
}
