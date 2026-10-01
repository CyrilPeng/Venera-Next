import 'package:sqlite3/sqlite3.dart';
import 'favorite_models.dart';
import 'favorite_row.dart';

/// Favorite persistence on a caller-owned connection; no cache or notifications.
class FavoritesRepository {
  FavoritesRepository(this.db);
  final Database db;

  void initializeMetadata() => _transaction(() {
    db.execute(
      'CREATE TABLE IF NOT EXISTS folder_order (folder_name TEXT PRIMARY KEY, order_value INT);',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS folder_sync (folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT);',
    );
  });

  Set<String> _columns(String folder) => db
      .select('PRAGMA table_info(${_table(folder)});')
      .map((row) => row['name'] as String)
      .toSet();

  void migrateTranslatedTags(
    List<String> folders,
    String Function(List<String>) translate,
  ) => _transaction(() {
    for (final folder in folders) {
      if (_columns(folder).contains('translated_tags')) continue;
      db.execute(
        'ALTER TABLE ${_table(folder)} ADD COLUMN translated_tags TEXT;',
      );
      for (final item in getFolderComics(folder)) {
        db.execute(
          'UPDATE ${_table(folder)} SET translated_tags = ? WHERE id = ? AND type = ?;',
          [translate(item.tags), item.id, item.type.value],
        );
      }
    }
  });

  void prepareForFollowUpdates(String folder, {required bool clearData}) =>
      _transaction(() {
        final columns = _columns(folder);
        for (final (name, type) in [
          ('last_update_time', 'TEXT'),
          ('has_new_update', 'INT'),
          ('last_check_time', 'INT'),
        ]) {
          if (!columns.contains(name)) {
            db.execute('ALTER TABLE ${_table(folder)} ADD COLUMN $name $type;');
          }
        }
        if (clearData) {
          db.execute('UPDATE ${_table(folder)} SET has_new_update = 0;');
        }
      });

  void createFolder(String folder) {
    db.execute('''
      CREATE TABLE ${_table(folder)} (
        id TEXT, name TEXT, author TEXT, type INT, tags TEXT, cover_path TEXT,
        time TEXT, display_order INT, translated_tags TEXT,
        PRIMARY KEY (id, type)
      );
    ''');
  }

  void renameFolder(String before, String after) => _transaction(() {
    db.execute('ALTER TABLE ${_table(before)} RENAME TO ${_table(after)};');
    db.execute(
      'UPDATE folder_order SET folder_name = ? WHERE folder_name = ?;',
      [after, before],
    );
    db.execute(
      'UPDATE folder_sync SET folder_name = ? WHERE folder_name = ?;',
      [after, before],
    );
  });

  void linkFolderToNetwork(String folder, String source, String networkFolder) {
    db.execute(
      'INSERT OR REPLACE INTO folder_sync (folder_name, source_key, source_folder) VALUES (?, ?, ?);',
      [folder, source, networkFolder],
    );
  }

  bool isLinkedToNetworkFolder(
    String folder,
    String source,
    String networkFolder,
  ) => db.select(
    'SELECT 1 FROM folder_sync WHERE folder_name = ? AND source_key = ? AND source_folder = ?;',
    [folder, source, networkFolder],
  ).isNotEmpty;

  (String?, String?) findLinked(String folder) {
    final rows = db.select(
      'SELECT source_key, source_folder FROM folder_sync WHERE folder_name = ?;',
      [folder],
    );
    return rows.isEmpty
        ? (null, null)
        : (rows.first['source_key'], rows.first['source_folder']);
  }

  Map<String, List<(String, int)>> deleteComics(
    List<String> folders,
    Iterable<(String, int)> identities,
  ) => _transaction(() {
    final requested = identities.toSet();
    final removed = <String, List<(String, int)>>{};
    for (final folder in folders) {
      for (final (id, type) in requested) {
        _removeRecord(folder, id, type);
        if (db.updatedRows > 0) (removed[folder] ??= []).add((id, type));
      }
    }
    return removed;
  });

  void deleteFolder(String folder) => _transaction(() {
    db.execute('DROP TABLE ${_table(folder)};');
    db.execute('DELETE FROM folder_order WHERE folder_name = ?;', [folder]);
    db.execute('DELETE FROM folder_sync WHERE folder_name = ?;', [folder]);
  });

  bool addComic(
    String folder,
    FavoriteItem item, {
    required String translatedTags,
    required bool append,
    int? order,
    String? updateTime,
  }) => _transaction(() {
    if (comicExists(folder, item.id, item.type.value)) return false;
    final position =
        order ?? (append ? maxValue(folder) + 1 : minValue(folder) - 1);
    db.execute(
      '''
      INSERT INTO ${_table(folder)}
        (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
      [
        item.id,
        item.name,
        item.author,
        item.type.value,
        item.tags.join(','),
        item.coverPath,
        item.time,
        translatedTags,
        position,
      ],
    );
    if (updateTime != null &&
        db
            .select('PRAGMA table_info(${_table(folder)});')
            .any((row) => row['name'] == 'last_update_time')) {
      db.execute(
        'UPDATE ${_table(folder)} SET last_update_time = ? WHERE id = ? AND type = ?;',
        [updateTime, item.id, item.type.value],
      );
    }
    return true;
  });

  void updateOrder(List<String> folders) => _transaction(() {
    for (var i = 0; i < folders.length; i++) {
      db.execute(
        'INSERT OR REPLACE INTO folder_order (folder_name, order_value) VALUES (?, ?);',
        [folders[i], i],
      );
    }
  });

  void addTagTo(String folder, String id, String tag) {
    db.execute('UPDATE ${_table(folder)} SET tags = ? || tags WHERE id = ?;', [
      '$tag,',
      id,
    ]);
  }

  void updateInfo(String folder, FavoriteItem item) {
    db.execute(
      'UPDATE ${_table(folder)} SET name = ?, author = ?, cover_path = ?, tags = ? WHERE id = ? AND type = ?;',
      [
        item.name,
        item.author,
        item.coverPath,
        item.tags.join(','),
        item.id,
        item.type.value,
      ],
    );
  }

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

  List<FavoriteItem> getFolderComics(String folder, {int? limit}) => db
      .select(
        'SELECT * FROM ${_table(folder)} ORDER BY display_order${limit == null ? "" : " LIMIT ?"};',
        limit == null ? [] : [limit],
      )
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

  Map<(String, int), int> referenceCounts(
    Iterable<String> folders,
    Iterable<(String, int)> requested,
  ) {
    final identities = requested.toSet().toList();
    final counts = <(String, int), int>{};
    // Keep each statement below legacy SQLite's 999 bound-variable limit.
    for (final folder in folders) {
      for (var start = 0; start < identities.length; start += 400) {
        final chunk = identities.skip(start).take(400).toList();
        final placeholders = List.filled(chunk.length, '(?, ?)').join(',');
        final rows = db.select(
          'SELECT id, type FROM ${_table(folder)} WHERE (id, type) IN (VALUES $placeholders);',
          [
            for (final (id, type) in chunk) ...[id, type],
          ],
        );
        for (final row in rows) {
          final identity = (row['id'] as String, row['type'] as int);
          counts[identity] = (counts[identity] ?? 0) + 1;
        }
      }
    }
    return counts;
  }

  List<(String, int)> identities(
    String folder, {
    bool updatedOnly = false,
  }) => db
      .select(
        'SELECT id, type FROM ${_table(folder)}${updatedOnly ? " WHERE has_new_update = 1" : ""};',
      )
      .map((row) => (row['id'] as String, row['type'] as int))
      .toList();

  List<FavoriteItem> exportComics(String folder) => db
      .select('SELECT * FROM ${_table(folder)};')
      .map(favoriteItemFromRow)
      .toList();

  void editTags(String folder, String id, List<String> tags) {
    db.execute('UPDATE ${_table(folder)} SET tags = ? WHERE id = ?;', [
      tags.join(','),
      id,
    ]);
  }

  /// Returns folders actually changed, only after all writes commit.
  List<String> recordRead(
    Iterable<String> folders,
    String id,
    int type, {
    required String time,
    required String? movement,
    required String? trackingFolder,
  }) => _transaction(() {
    final changed = <String>[];
    for (final folder in folders) {
      if (!comicExists(folder, id, type)) continue;
      final position = switch (movement) {
        'start' => minValue(folder) - 1,
        'end' => maxValue(folder) + 1,
        _ => null,
      };
      db.execute(
        'UPDATE ${_table(folder)} SET ${position == null ? "" : "display_order = ?, "}${folder == trackingFolder ? "has_new_update = 0, " : ""}time = ? WHERE id = ? AND type = ?;',
        [?position, time, id, type],
      );
      changed.add(folder);
    }
    return changed;
  });

  bool updateUpdateTime(
    String folder,
    String id,
    int type,
    String updateTime,
    int checkedAt,
  ) => _transaction(() {
    final oldTime = db.select(
      'SELECT last_update_time FROM ${_table(folder)} WHERE id = ? AND type = ?;',
      [id, type],
    ).first['last_update_time'];
    final changed = oldTime != updateTime;
    db.execute(
      'UPDATE ${_table(folder)} SET last_update_time = ?, has_new_update = ?, last_check_time = ? WHERE id = ? AND type = ?;',
      [updateTime, changed ? 1 : 0, checkedAt, id, type],
    );
    return changed;
  });

  void updateCheckTime(String folder, String id, int type, int checkedAt) {
    db.execute(
      'UPDATE ${_table(folder)} SET last_check_time = ? WHERE id = ? AND type = ?;',
      [checkedAt, id, type],
    );
  }

  int countUpdates(String folder) =>
      db
              .select(
                'SELECT COUNT(*) AS c FROM ${_table(folder)} WHERE has_new_update = 1;',
              )
              .first['c']
          as int;

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(
    String folder, {
    bool updatedOnly = false,
  }) => db
      .select(
        'SELECT * FROM ${_table(folder)}${updatedOnly ? " WHERE has_new_update = 1" : ""};',
      )
      .map(favoriteItemWithUpdateInfoFromRow)
      .toList();

  void markAsRead(String folder, String id, int type) {
    db.execute(
      'UPDATE ${_table(folder)} SET has_new_update = 0 WHERE id = ? AND type = ?;',
      [id, type],
    );
  }

  void reorder(
    String folder,
    Iterable<(String, int)> identities,
  ) => _transaction(() {
    var order = 0;
    for (final (id, type) in identities) {
      db.execute(
        'UPDATE ${_table(folder)} SET display_order = ? WHERE id = ? AND type = ?;',
        [order++, id, type],
      );
    }
  });

  List<FavoriteItem> _searchFirstToken(String folder, String token) => db
      .select(
        'SELECT * FROM ${_table(folder)} WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;',
        List.filled(4, '%$token%'),
      )
      .map(favoriteItemFromRow)
      .toList();

  static bool _matches(FavoriteItem item, String token) =>
      item.name.contains(token) ||
      item.author.contains(token) ||
      item.tags.any((tag) => tag.contains(token));

  List<FavoriteItem> searchInFolder(String folder, String keyword) {
    final tokens = keyword.split(' ');
    return _searchFirstToken(folder, tokens.first)
        .where((item) => tokens.skip(1).every((token) => _matches(item, token)))
        .toList();
  }

  List<FavoriteItem> search(Iterable<String> folders, String keyword) {
    final tokens = keyword.split(' ');
    final candidates = <FavoriteItem>{};
    for (final folder in folders) {
      candidates.addAll(_searchFirstToken(folder, tokens.first));
      // Preserve the existing folder-level cutoff before secondary filtering.
      if (candidates.length > 200) break;
    }
    return candidates.where((item) {
      return tokens.skip(1).every((token) {
        token = token.trim();
        return token.isEmpty || _matches(item, token);
      });
    }).toList();
  }

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
