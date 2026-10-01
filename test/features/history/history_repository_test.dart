import 'package:venera_next/features/history/history_cache.dart';
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

  test('metadata updates only supplied fields on the requested source', () {
    repository.writeProgress(item());
    repository.writeProgress(item(type: 1));
    expect(
      repository.updateMetadata('shared', 0, cover: '', subtitle: ''),
      isTrue,
    );
    final stored = repository.find('shared', 0)!;
    expect(stored.title, 'Book');
    expect(stored.subtitle, '');
    expect(stored.cover, '');
    expect(stored.page, 3);
    expect(stored.time.millisecondsSinceEpoch, 1000);
    expect(repository.find('shared', 1)!.cover, 'cover');
    expect(repository.updateMetadata('absent', 0, title: 'No insert'), isFalse);
    expect(repository.updateMetadata('shared', 0), isFalse);
    expect(repository.count(), 2);
  });

  test('failed imported metadata rolls back its preceding progress update', () {
    repository.writeProgress(item());
    db.execute(
      "CREATE TRIGGER reject_metadata BEFORE UPDATE OF title ON history BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    expect(
      () => repository.importHistory(
        item()
          ..page = 9
          ..title = 'Import',
      ),
      throwsA(isA<SqliteException>()),
    );
    final stored = repository.find('shared', 0)!;
    expect(stored.page, 3);
    expect(stored.title, 'Book');
  });

  test(
    'cache distinguishes shared IDs by source and refresh evicts only deleted identity',
    () {
      final queriedIds = <String?>[];
      final cache = HistoryCache(
        identities: ({String? id}) {
          queriedIds.add(id);
          return repository.identities(id: id);
        },
        load: repository.find,
      );
      final a = item();
      final b = item(type: 1)..title = 'Other source';
      repository.writeProgress(a);
      cache.record(a);
      repository.writeProgress(b);
      cache.record(b);
      expect(identical(cache.find('shared', 0), a), isTrue);
      expect(identical(cache.find('shared', 1), b), isTrue);
      expect(cache.find('shared', 2), isNull);
      expect(queriedIds, [null, 'shared']);
      repository.remove('shared', 1);
      cache.refresh();
      expect(cache.find('shared', 1), isNull);
      expect(identical(cache.find('shared', 0), a), isTrue);
    },
  );

  test('cache observes source replacement under an id-only primary key', () {
    db.execute('DROP TABLE history');
    repository.initialize();
    final cache = HistoryCache(
      identities: repository.identities,
      load: repository.find,
    );
    final a = item();
    final b = item(type: 1);
    repository.writeProgress(a);
    cache.record(a);
    repository.writeProgress(b);
    cache.record(b);
    expect(repository.count(), 1);
    expect(cache.find('shared', 0), isNull);
    expect(identical(cache.find('shared', 1), b), isTrue);
    cache.clear();
    expect(cache.find('shared', 0), isNull);
    expect(cache.find('shared', 1)?.type.value, 1);
  });

  test(
    'cache capacity remains ten and mutated identity never satisfies an old key',
    () {
      final cache = HistoryCache(
        identities: repository.identities,
        load: repository.find,
      );
      final values = List.generate(11, (index) => item()..id = '$index');
      for (final value in values) {
        repository.writeProgress(value);
        cache.record(value);
      }
      expect(identical(cache.find('0', 0), values.first), isFalse);
      expect(identical(cache.find('10', 0), values.last), isTrue);
      values.last.id = 'changed';
      expect(cache.find('10', 0)?.id, '10');
      expect(cache.find('changed', 0), isNull);
      repository.clear();
      cache.clear();
      expect(cache.find('0', 0), isNull);
    },
  );

  test(
    'queries retain recent limits, duration ordering and retention boundary',
    () {
      for (var index = 0; index < 25; index++) {
        final value = item()
          ..id = '$index'
          ..time = DateTime.fromMillisecondsSinceEpoch(index);
        repository.writeProgress(value);
        if (index >= 23) repository.addReadDuration(value, 10);
      }
      expect(repository.count(), 25);
      expect(repository.identities(), hasLength(25));
      expect(repository.getAll().first.id, '24');
      expect(
        repository.getRecent().map((value) => value.id),
        List.generate(20, (index) => '${24 - index}'),
      );
      expect(repository.getTotalReadDurationMs(), 20);
      expect(repository.countWithReadDuration(), 2);
      expect(repository.getAllByReadDuration().map((value) => value.id), [
        '24',
        '23',
      ]);
      expect(repository.find('24', 0)?.id, '24');
      expect(repository.find('24', 1), isNull);
      repository.clearBefore(23);
      expect(repository.getAll().map((value) => value.id), ['24', '23']);
      repository.remove('24', 1);
      expect(repository.count(), 2);
      repository.removeMany([('24', 0), ('23', 0)]);
      expect(repository.count(), 0);
      expect(repository.getTotalReadDurationMs(), 0);
      repository.writeProgress(item());
      repository.clear();
      expect(repository.identities(), isEmpty);
    },
  );

  test(
    'conditional and batch deletion roll back earlier removals on failure',
    () {
      repository.writeProgress(item()..id = 'a');
      repository.writeProgress(item()..id = 'b');
      var visited = 0;
      expect(
        () => repository.deleteWhere((id, type) {
          if (++visited == 2) throw StateError('favorite lookup');
          return true;
        }),
        throwsStateError,
      );
      expect(repository.count(), 2);
      db.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON history WHEN OLD.id = 'b' BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
      );
      expect(
        () => repository.removeMany([('a', 0), ('b', 0)]),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.count(), 2);
      db.execute('DROP TRIGGER reject_delete');
      repository.deleteWhere((id, type) => id == 'a');
      expect(repository.getAll().single.id, 'b');
    },
  );

  test(
    'initialization is repeatable and migrates legacy rows without changing identity',
    () {
      db.execute('DROP TABLE history');
      db.execute(
        'CREATE TABLE history (id TEXT, type INT, title TEXT, subtitle TEXT, cover TEXT, time INT, ep INT, page INT, readEpisode TEXT, max_page INT)',
      );
      db.execute(
        "INSERT INTO history VALUES ('old', 0, 'Legacy', '', '', 1000, 2, 8, '1,2', 10)",
      );
      repository.initialize();
      repository.initialize();
      final legacy = repository.find('old', 0)!;
      expect(legacy.page, 8);
      expect(legacy.readEpisode, {'1', '2'});
      expect(legacy.group, isNull);
      expect(legacy.readDurationMs, 0);
      repository.writeProgress(legacy..page = 9);
      expect(repository.count(), 1);
      db.execute('DROP TABLE history');
      repository.initialize();
      expect(repository.count(), 0);
    },
  );

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
