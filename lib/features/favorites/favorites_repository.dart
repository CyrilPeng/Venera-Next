import 'package:sqlite3/sqlite3.dart';
import 'favorite_models.dart';
import 'favorite_row.dart';

/// Favorite queries on a caller-owned connection; no cache or notifications.
class FavoritesRepository {
  FavoritesRepository(this.db);
  final Database db;

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
