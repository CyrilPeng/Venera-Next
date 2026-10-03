import 'dart:convert';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'local_comic_model.dart';
import 'local_comic_row.dart';
import 'local_sort_type.dart';

/// A persisted page conversion; null fields mark an already natural-sorted book.
class LocalPageMigration {
  const LocalPageMigration(this.historyTime, this.oldPage, this.newPage);

  final int? historyTime;
  final int? oldPage;
  final int? newPage;
}

/// Local comic persistence on a caller-owned connection.
class LocalRepository {
  LocalRepository(this.db);
  final Database db;
  void initialize() => runSqliteTransaction(db, () {
    db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS natural_sort_migration (
        id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        history_time INTEGER,
        old_page INTEGER,
        new_page INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
  });

  LocalPageMigration? findPageMigration(String id, ComicType type) {
    final rows = db.select(
      'SELECT history_time, old_page, new_page FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
      [id, type.value],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LocalPageMigration(
      row['history_time'] as int?,
      row['old_page'] as int?,
      row['new_page'] as int?,
    );
  }

  /// The first persisted mapping wins, including a new-import marker inserted
  /// while the caller was asynchronously enumerating images.
  LocalPageMigration recordPageMigration(
    String id,
    ComicType type,
    LocalPageMigration migration,
  ) => runSqliteTransaction(db, () {
    db.execute(
      'INSERT INTO natural_sort_migration (id, comic_type, history_time, old_page, new_page) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id, comic_type) DO NOTHING',
      [
        id,
        type.value,
        migration.historyTime,
        migration.oldPage,
        migration.newPage,
      ],
    );
    return findPageMigration(id, type)!;
  });

  String findValidId(ComicType type) {
    final res = db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse(res.first['id'] as String) + 1).toString();
  }

  void add(LocalComic comic, [String? id]) => runSqliteTransaction(db, () {
    final targetId = id ?? comic.id;
    final old = find(targetId, comic.comicType);
    if (old == null) {
      db.execute(
        'INSERT OR REPLACE INTO natural_sort_migration (id, comic_type) VALUES (?, ?)',
        [targetId, comic.comicType.value],
      );
    }
    final downloaded = [
      ...comic.downloadedChapters,
      ...?old?.downloadedChapters,
    ];
    db.execute(
      'INSERT OR REPLACE INTO comics (id, title, subtitle, tags, directory, chapters, cover, comic_type, downloadedChapters, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        targetId,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
  });

  void remove(String id, ComicType type) =>
      runSqliteTransaction(db, () => _remove(id, type));

  void removeAll(Iterable<LocalComic> comics) => runSqliteTransaction(db, () {
    for (final comic in comics) {
      _remove(comic.id, comic.comicType);
    }
  });

  /// Read the current stored chapters so stale UI models cannot discard a
  /// chapter downloaded after the page was opened.
  void removeChapters(String id, ComicType type, List<String> chapters) {
    if (chapters.isEmpty) return;
    final selected = chapters.toSet();
    runSqliteTransaction(db, () {
      final comic = find(id, type);
      if (comic == null) return;
      final remaining = comic.downloadedChapters
          .where((chapter) => !selected.contains(chapter))
          .toList();
      if (remaining.isEmpty) {
        _remove(id, type);
      } else {
        db.execute(
          'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?',
          [jsonEncode(remaining), id, type.value],
        );
      }
    });
  }

  void _remove(String id, ComicType type) {
    db.execute(
      'DELETE FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
      [id, type.value],
    );
    db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?', [
      id,
      type.value,
    ]);
  }

  /// Detect record/ownership changes while filesystem staging awaits I/O.
  String deletionSnapshot() => jsonEncode(
    db
        .select(
          'SELECT id, comic_type, directory, downloadedChapters FROM comics ORDER BY id, comic_type',
        )
        .map(
          (row) => [
            row['id'],
            row['comic_type'],
            row['directory'],
            row['downloadedChapters'],
          ],
        )
        .toList(),
  );

  /// Directory ownership does not require decoding display/reading metadata.
  List<String> directoryReferences({
    (String, ComicType)? excluding,
    Iterable<(String, ComicType)> excludingMany = const [],
  }) {
    final excluded = {
      if (excluding != null) (excluding.$1, excluding.$2.value),
      for (final identity in excludingMany) (identity.$1, identity.$2.value),
    };
    return [
      for (final row in db.select(
        'SELECT id, comic_type, directory FROM comics',
      ))
        if (!excluded.contains((row['id'], row['comic_type'])))
          row['directory'] as String,
    ];
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    var res = db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => localComicFromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return localComicFromRow(res.first);
  }

  List<LocalComic> getRecent() {
    final res = db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => localComicFromRow(row)).toList();
  }

  int get count {
    final res = db.select('''
      SELECT COUNT(*) AS total FROM comics;
    ''');
    return res.first['total'] as int;
  }

  LocalComic? findByName(String name) {
    final res = db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return localComicFromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => localComicFromRow(row)).toList();
  }
}
