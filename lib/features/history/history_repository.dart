import 'history_row.dart';
import 'package:sqlite3/sqlite3.dart';
import 'history_model.dart';

/// History schema, queries and writes on a caller-owned connection.
/// The manager owns scheduling, connection lifetime, caching and notifications.
class HistoryRepository {
  HistoryRepository(this.db);
  final Database db;

  void initialize() {
    db.execute("""
        create table if not exists history  (
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

    var columns = db.select("PRAGMA table_info(history);");
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      db.execute("alter table history add column chapter_group int;");
    }
    if (!columns.any((element) => element["name"] == "read_duration_ms")) {
      db.execute(
        "alter table history add column read_duration_ms integer not null default 0;",
      );
    }
  }

  List<History> getAll() {
    var res = db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => historyFromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => historyFromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  int getTotalReadDurationMs() {
    var res = db.select("""
      select coalesce(sum(read_duration_ms), 0) from history;
    """);
    return (res.first[0] as num).round();
  }

  int countWithReadDuration() {
    var res = db.select("""
      select count(*) from history where read_duration_ms > 0;
    """);
    return (res.first[0] as num).round();
  }

  List<History> getAllByReadDuration() {
    var res = db.select("""
      select * from history
      where read_duration_ms > 0
      order by read_duration_ms desc, time desc;
    """);
    return res.map(historyFromRow).toList();
  }

  History? find(String id, int type) {
    var res = db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type],
    );
    if (res.isEmpty) {
      return null;
    }
    return historyFromRow(res.first);
  }

  void deleteWhere(bool Function(String id, int type) shouldDelete) {
    db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = element["type"] as int;
        if (shouldDelete(id, type)) {
          db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type],
          );
        }
      }
      db.execute('COMMIT;');
    } catch (e) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void remove(String id, int type) {
    db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type],
    );
  }

  void removeMany(Iterable<(String, int)> identities) {
    db.execute('BEGIN TRANSACTION;');
    try {
      for (final (id, type) in identities) {
        remove(id, type);
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void clearBefore(int cutoff) {
    db.execute(
      """
      delete from history
      where time < ?;
    """,
      [cutoff],
    );
  }

  void clear() => db.execute("delete from history;");

  List<(String, int)> identities({String? id}) => db
      .select(
        id == null
            ? 'select id, type from history;'
            : 'select id, type from history where id = ?;',
        id == null ? const [] : [id],
      )
      .map((row) => (row['id'] as String, row['type'] as int))
      .toList();

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static const _updateHistorySql = """
        update history set
          title = ?,
          subtitle = ?,
          cover = ?,
          time = ?,
          ep = ?,
          page = ?,
          readEpisode = ?,
          max_page = ?,
          chapter_group = ?
        where id = ? and type = ?;
      """;

  static const _insertReadDurationSql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static const _incrementReadDurationSql = """
        update history
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

  static void _runWriteTransaction(Database db, void Function() write) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      write();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  // Legacy databases do not consistently expose a single-column UNIQUE(id).
  void writeProgress(History item) {
    _runWriteTransaction(db, () {
      db.execute(_updateHistorySql, [
        item.title,
        item.subtitle,
        item.cover,
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
      }
    });
  }

  void addReadDuration(History item, int durationMs) {
    _runWriteTransaction(db, () {
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
    });
  }
}
