import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/history_contract.dart';
import 'history_model.dart';

/// Decode the existing SQLite representation after schema migration.
History historyFromRow(Row row) => History(
  type: HistoryType(row['type']),
  time: DateTime.fromMillisecondsSinceEpoch(row['time']),
  title: row['title'],
  subtitle: row['subtitle'],
  cover: row['cover'],
  ep: row['ep'],
  page: row['page'],
  id: row['id'],
  readEpisode: Set<String>.from(
    (row['readEpisode'] as String).split(',').where((entry) => entry != ''),
  ),
  maxPage: row['max_page'],
  group: row['chapter_group'],
  readDurationMs: (row['read_duration_ms'] as num).round(),
);
