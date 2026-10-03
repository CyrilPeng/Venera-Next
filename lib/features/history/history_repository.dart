import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'history_row.dart';
import 'package:sqlite3/sqlite3.dart';
import 'history_model.dart';

/// History schema, queries and writes on a caller-owned connection.
/// The manager owns scheduling, connection lifetime, caching and notifications.
class HistoryRepository {
  HistoryRepository(this.db, {String schema = 'main'})
    : _schema = '"${schema.replaceAll('"', '""')}"';
  final Database db;
  final String _schema;
  String get _table => '$_schema."history"';

  void initialize() {
    db.execute("""
        create table if not exists $_table  (
          id text primary key,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          read_duration_ms integer not null default 0
        );
      """);

    var columns = db.select('PRAGMA $_schema.table_info("history");');
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      db.execute("alter table $_table add column chapter_group int;");
    }
    if (!columns.any((element) => element["name"] == "read_duration_ms")) {
      db.execute(
        "alter table $_table add column read_duration_ms integer not null default 0;",
      );
    }
  }

  List<History> getAll() {
    var res = db.select("""
      select * from $_table
      order by time DESC;
    """);
    return res.map((element) => historyFromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = db.select("""
      select * from $_table
      order by time DESC
      limit 20;
    """);
    return res.map((element) => historyFromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = db.select("""
      select count(*) AS total from $_table;
    """);
    return res.first['total'] as int;
  }

  int getTotalReadDurationMs() {
    var res = db.select("""
      select coalesce(sum(read_duration_ms), 0) AS total from $_table;
    """);
    return (res.first['total'] as num).round();
  }

  int countWithReadDuration() {
    var res = db.select("""
      select count(*) AS total from $_table where read_duration_ms > 0;
    """);
    return (res.first['total'] as num).round();
  }

  List<History> getAllByReadDuration() {
    var res = db.select("""
      select * from $_table
      where read_duration_ms > 0
      order by read_duration_ms desc, time desc;
    """);
    return res.map(historyFromRow).toList();
  }

  History? find(String id, int type) {
    var res = db.select(
      """
      select * from $_table
      where id == ? and type == ?;
    """,
      [id, type],
    );
    if (res.isEmpty) {
      return null;
    }
    return historyFromRow(res.first);
  }

  void deleteWhere(bool Function(String id, int type) shouldDelete) =>
      runSqliteTransaction(db, () {
        final idAndTypes = db.select("""
      select id, type from $_table;
    """);
        for (var element in idAndTypes) {
          final id = element["id"] as String;
          final type = element["type"] as int;
          if (shouldDelete(id, type)) {
            db.execute(
              """
          delete from $_table
          where id == ? and type == ?;
        """,
              [id, type],
            );
          }
        }
      });

  void remove(String id, int type) {
    db.execute(
      """
      delete from $_table
      where id == ? and type == ?;
    """,
      [id, type],
    );
  }

  void removeMany(Iterable<(String, int)> identities) =>
      runSqliteTransaction(db, () {
        for (final (id, type) in identities) {
          remove(id, type);
        }
      });

  void clearBefore(int cutoff) {
    db.execute(
      """
      delete from $_table
      where time < ?;
    """,
      [cutoff],
    );
  }

  void clear() => db.execute("delete from $_table;");

  List<(String, int)> identities({String? id}) => db
      .select(
        id == null
            ? 'select id, type from $_table;'
            : 'select id, type from $_table where id = ?;',
        id == null ? const [] : [id],
      )
      .map((row) => (row['id'] as String, row['type'] as int))
      .toList();

  String get _insertHistorySql =>
      """
        insert or replace into $_table (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  /// Metadata refreshes never replace progress or recreate deleted records.
  bool updateMetadata(
    String id,
    int type, {
    String? title,
    String? subtitle,
    String? cover,
  }) {
    final fields = <String, String>{
      'title': ?title,
      'subtitle': ?subtitle,
      'cover': ?cover,
    };
    if (fields.isEmpty) return false;
    db.execute(
      'UPDATE $_table SET ${fields.keys.map((field) => '$field = ?').join(', ')} '
      'WHERE id = ? AND type = ?;',
      [...fields.values, id, type],
    );
    return db.updatedRows > 0;
  }

  String get _updateHistorySql =>
      """
        update $_table set
          time = ?,
          ep = ?,
          page = ?,
          readEpisode = ?,
          max_page = ?,
          chapter_group = ?
        where id = ? and type = ?;
      """;

  String get _insertReadDurationSql =>
      """
        insert or replace into $_table (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  String get _incrementReadDurationSql =>
      """
        update $_table
        set read_duration_ms = read_duration_ms + ?
        where id = ? and type = ?;
      """;

  static List<Object?> _historyValues(History item) {
    return [
      item.id,
      item.title,
      item.subtitle,
      item.cover,
      item.time.millisecondsSinceEpoch,
      item.type.value,
      item.ep,
      item.page,
      item.readEpisode.join(','),
      item.maxPage,
      item.group,
    ];
  }

  // Legacy databases do not consistently expose a single-column UNIQUE(id).
  void writeProgress(History item) =>
      _writeHistory(item, replaceMetadata: false);

  /// Imports deliberately replace metadata as well as progress. Duration keeps
  /// the existing import policy and is not replaced by a progress snapshot.
  void importHistory(History item) =>
      _writeHistory(item, replaceMetadata: true);

  void _writeHistory(History item, {required bool replaceMetadata}) {
    runSqliteTransaction(db, () {
      db.execute(_updateHistorySql, [
        item.time.millisecondsSinceEpoch,
        item.ep,
        item.page,
        item.readEpisode.join(','),
        item.maxPage,
        item.group,
        item.id,
        item.type.value,
      ]);
      if (db.updatedRows == 0) {
        db.execute(_insertHistorySql, _historyValues(item));
      } else if (replaceMetadata) {
        updateMetadata(
          item.id,
          item.type.value,
          title: item.title,
          subtitle: item.subtitle,
          cover: item.cover,
        );
      }
    }, immediate: true);
  }

  void addReadDuration(History item, int durationMs) {
    runSqliteTransaction(db, () {
      db.execute(_incrementReadDurationSql, [
        durationMs,
        item.id,
        item.type.value,
      ]);
      if (db.updatedRows == 0) {
        db.execute(_insertReadDurationSql, [
          ..._historyValues(item),
          durationMs,
        ]);
      }
    }, immediate: true);
  }
}
