import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/features/history/history_row.dart';

History item({int type = 0}) => History.fromMap({
  'id': 'shared',
  'type': type,
  'title': 'Book',
  'subtitle': 'Author',
  'cover': 'cover',
  'time': 1000,
  'ep': 2,
  'page': 3,
  'readEpisode': ['1', '2-2'],
  'max_page': 10,
});

void main() {
  late Database db;
  late HistoryRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE history (
        id TEXT, type INT, title TEXT, subtitle TEXT, cover TEXT, time INT,
        ep INT, page INT, readEpisode TEXT, max_page INT, chapter_group INT,
        read_duration_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (id, type)
      );
    ''');
    repository = HistoryRepository(db);
  });
  tearDown(() => db.dispose());

  test(
    'row mapping preserves grouped coordinates, nulls, rounding and empty read tokens',
    () {
      repository.writeProgress(item()..group = 2);
      db.execute(
        "UPDATE history SET readEpisode = ',1,,2-2,1,', max_page = NULL, read_duration_ms = 7.6",
      );
      final restored = historyFromRow(
        db.select('SELECT * FROM history').single,
      );
      expect(restored.id, 'shared');
      expect(restored.type.value, 0);
      expect(restored.time.millisecondsSinceEpoch, 1000);
      expect(restored.title, 'Book');
      expect(restored.subtitle, 'Author');
      expect(restored.cover, 'cover');
      expect(restored.ep, 2);
      expect(restored.page, 3);
      expect(restored.group, 2);
      expect(restored.maxPage, isNull);
      expect(restored.readEpisode, {'1', '2-2'});
      expect(restored.readDurationMs, 8);
    },
  );

  test(
    'progress writes preserve duration and isolate same IDs by source type',
    () {
      final first = item();
      repository.writeProgress(first);
      repository.writeProgress(item(type: 1));
      repository.addReadDuration(first, 120);
      first.page = 8;
      first.readDurationMs = 999;
      repository.writeProgress(first);
      final rows = db
          .select('SELECT * FROM history ORDER BY type')
          .map(historyFromRow)
          .toList();
      expect(rows, hasLength(2));
      expect(rows.first.page, 8);
      expect(rows.first.readDurationMs, 120);
      expect(rows.last.page, 3);
      expect(rows.last.readDurationMs, 0);
    },
  );

  test(
    'duration can create a row and failed progress transaction permits later writes',
    () {
      final original = item()..group = 2;
      repository.addReadDuration(original, 40);
      db.execute(
        "CREATE TRIGGER reject_update BEFORE UPDATE ON history BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
      );
      original.page = 9;
      expect(
        () => repository.writeProgress(original),
        throwsA(isA<SqliteException>()),
      );
      expect(historyFromRow(db.select('SELECT * FROM history').single).page, 3);
      db.execute('DROP TRIGGER reject_update');
      repository.writeProgress(original);
      repository.addReadDuration(original, 10);
      final restored = historyFromRow(
        db.select('SELECT * FROM history').single,
      );
      expect(restored.page, 9);
      expect(restored.group, 2);
      expect(restored.readDurationMs, 50);
    },
  );
}
