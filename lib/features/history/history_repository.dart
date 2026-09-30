import 'package:sqlite3/sqlite3.dart';
import 'history_model.dart';

/// SQL writes on a caller-owned connection. The manager owns scheduling,
/// connection lifetime, schema migration, caching and notifications.
class HistoryRepository {
  HistoryRepository(this.db);
  final Database db;

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
