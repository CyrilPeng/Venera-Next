import 'dart:convert';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'local_comic_model.dart';
import 'local_comic_row.dart';
import 'local_sort_type.dart';

/// Local comic queries on a caller-owned connection.
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
    return (int.parse((res.first[0])) + 1).toString();
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

  void remove(String id, ComicType type) => runSqliteTransaction(db, () {
    db.execute(
      'DELETE FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
      [id, type.value],
    );
    db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?', [
      id,
      type.value,
    ]);
  });

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
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
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
