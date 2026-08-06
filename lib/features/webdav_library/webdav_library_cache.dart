import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

class WebDavLibraryCachedComic {
  const WebDavLibraryCachedComic({
    required this.id,
    required this.sortIndex,
    required this.title,
    required this.author,
    required this.tags,
    required this.cover,
    required this.snapshot,
    required this.remoteETag,
    required this.remoteModifiedAt,
  });

  factory WebDavLibraryCachedComic.fromRow(Row row) {
    final tags = jsonDecode(row['tags'] as String);
    final snapshotText = row['snapshot_json'] as String?;
    return WebDavLibraryCachedComic(
      id: row['id'] as String,
      sortIndex: row['sort_index'] as int,
      title: row['title'] as String,
      author: row['author'] as String,
      tags: tags is List ? tags.whereType<String>().toList() : const [],
      cover: row['cover'] as String,
      snapshot: snapshotText == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(snapshotText) as Map),
      remoteETag: row['remote_etag'] as String?,
      remoteModifiedAt: row['remote_modified_at'] as int?,
    );
  }

  final String id;
  final int sortIndex;
  final String title;
  final String author;
  final List<String> tags;
  final String cover;
  final Map<String, dynamic>? snapshot;
  final String? remoteETag;
  final int? remoteModifiedAt;

  bool get isReady => snapshot != null;

  bool hasSameRemoteVersion({String? eTag, int? modifiedAt}) {
    final hasVersion = (eTag?.isNotEmpty ?? false) || modifiedAt != null;
    if (!hasVersion) return true;
    return remoteETag == eTag && remoteModifiedAt == modifiedAt;
  }
}

class WebDavLibraryRemoteDirectory {
  const WebDavLibraryRemoteDirectory({
    required this.id,
    required this.sortIndex,
    this.eTag,
    this.modifiedAt,
  });

  final String id;
  final int sortIndex;
  final String? eTag;
  final int? modifiedAt;
}

class WebDavLibraryCache {
  WebDavLibraryCache._();

  static final instance = WebDavLibraryCache._();

  Database? _db;
  String? _dbPath;

  Database get _database {
    final path = '${App.dataPath}/webdav_library.db';
    if (_db != null && _dbPath == path) return _db!;
    _db?.dispose();
    _dbPath = path;
    final db = openSqliteDatabase(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_comics (
        config_key TEXT NOT NULL,
        id TEXT NOT NULL,
        sort_index INTEGER NOT NULL,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        snapshot_json TEXT,
        remote_etag TEXT,
        remote_modified_at INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (config_key, id)
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS webdav_library_comics_page
      ON webdav_library_comics(config_key, sort_index);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_state (
        config_key TEXT PRIMARY KEY,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        index_initialized INTEGER NOT NULL DEFAULT 0
      );
    ''');
    final stateColumns = db.select('PRAGMA table_info(webdav_library_state);');
    if (!stateColumns.any((row) => row['name'] == 'index_initialized')) {
      db.execute(
        'ALTER TABLE webdav_library_state ADD COLUMN index_initialized INTEGER NOT NULL DEFAULT 0;',
      );
    }
    _db = db;
    return db;
  }

  int count(String configKey) {
    return _database.select(
          'SELECT COUNT(*) AS count FROM webdav_library_comics WHERE config_key = ?;',
          [configKey],
        ).single['count']
        as int;
  }

  List<WebDavLibraryCachedComic> page(
    String configKey, {
    required int page,
    required int pageSize,
  }) {
    final offset = (page - 1) * pageSize;
    return _database
        .select(
          '''
          SELECT * FROM webdav_library_comics
          WHERE config_key = ?
          ORDER BY sort_index
          LIMIT ? OFFSET ?;
          ''',
          [configKey, pageSize, offset],
        )
        .map(WebDavLibraryCachedComic.fromRow)
        .toList();
  }

  Map<String, WebDavLibraryCachedComic> all(String configKey) {
    return {
      for (final row in _database.select(
        'SELECT * FROM webdav_library_comics WHERE config_key = ?;',
        [configKey],
      ))
        row['id'] as String: WebDavLibraryCachedComic.fromRow(row),
    };
  }

  WebDavLibraryCachedComic? find(String configKey, String id) {
    final rows = _database.select(
      '''
      SELECT * FROM webdav_library_comics
      WHERE config_key = ? AND id = ?
      LIMIT 1;
      ''',
      [configKey, id],
    );
    return rows.isEmpty ? null : WebDavLibraryCachedComic.fromRow(rows.single);
  }

  void replaceDirectoryIndex(
    String configKey,
    List<WebDavLibraryRemoteDirectory> directories,
  ) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final remoteIds = directories.map((entry) => entry.id).toSet();
      final cachedIds = db
          .select(
            'SELECT id FROM webdav_library_comics WHERE config_key = ?;',
            [configKey],
          )
          .map((row) => row['id'] as String);
      for (final id in cachedIds) {
        if (!remoteIds.contains(id)) {
          db.execute(
            'DELETE FROM webdav_library_comics WHERE config_key = ? AND id = ?;',
            [configKey, id],
          );
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final directory in directories) {
        db.execute(
          '''
          INSERT INTO webdav_library_comics (
            config_key, id, sort_index, title, author, tags, cover,
            snapshot_json, remote_etag, remote_modified_at, updated_at
          ) VALUES (?, ?, ?, ?, '', '[]', '', NULL, ?, ?, ?)
          ON CONFLICT(config_key, id) DO UPDATE SET
            sort_index = excluded.sort_index;
          ''',
          [
            configKey,
            directory.id,
            directory.sortIndex,
            directory.id,
            directory.eTag,
            directory.modifiedAt,
            now,
          ],
        );
      }
      db.execute(
        '''
        INSERT INTO webdav_library_state(
          config_key, last_successful_sync, index_initialized
        ) VALUES (?, 0, 1)
        ON CONFLICT(config_key) DO UPDATE SET index_initialized = 1;
        ''',
        [configKey],
      );
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void upsertSnapshot(String configKey, WebDavLibraryCachedComic comic) {
    _database.execute(
      '''
      INSERT INTO webdav_library_comics (
        config_key, id, sort_index, title, author, tags, cover,
        snapshot_json, remote_etag, remote_modified_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(config_key, id) DO UPDATE SET
        sort_index = excluded.sort_index,
        title = excluded.title,
        author = excluded.author,
        tags = excluded.tags,
        cover = excluded.cover,
        snapshot_json = excluded.snapshot_json,
        remote_etag = excluded.remote_etag,
        remote_modified_at = excluded.remote_modified_at,
        updated_at = excluded.updated_at;
      ''',
      [
        configKey,
        comic.id,
        comic.sortIndex,
        comic.title,
        comic.author,
        jsonEncode(comic.tags),
        comic.cover,
        jsonEncode(comic.snapshot),
        comic.remoteETag,
        comic.remoteModifiedAt,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  int lastSuccessfulSync(String configKey) {
    final rows = _database.select(
      'SELECT last_successful_sync FROM webdav_library_state WHERE config_key = ?;',
      [configKey],
    );
    return rows.isEmpty ? 0 : rows.single['last_successful_sync'] as int;
  }

  bool hasDirectoryIndex(String configKey) {
    final rows = _database.select(
      'SELECT index_initialized FROM webdav_library_state WHERE config_key = ?;',
      [configKey],
    );
    return rows.isNotEmpty && rows.single['index_initialized'] == 1;
  }

  void setLastSuccessfulSync(String configKey, int timestamp) {
    _database.execute(
      '''
      INSERT INTO webdav_library_state(config_key, last_successful_sync)
      VALUES (?, ?)
      ON CONFLICT(config_key) DO UPDATE SET
        last_successful_sync = excluded.last_successful_sync;
      ''',
      [configKey, timestamp],
    );
  }

  void clear(String configKey) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('DELETE FROM webdav_library_comics WHERE config_key = ?;', [
        configKey,
      ]);
      db.execute('DELETE FROM webdav_library_state WHERE config_key = ?;', [
        configKey,
      ]);
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void resetForTesting() {
    _db?.dispose();
    _db = null;
    _dbPath = null;
  }
}
