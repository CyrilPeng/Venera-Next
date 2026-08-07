import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/res.dart';

History _history(String id) {
  return History.fromMap({
    'type': ComicType.local.value,
    'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
    'title': 'Title $id',
    'subtitle': 'Author',
    'cover': 'cover.jpg',
    'ep': 1,
    'page': 2,
    'id': id,
    'readEpisode': ['1'],
    'max_page': 10,
  });
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('History.fromMap defaults missing reading duration to zero', () {
    expect(_history('legacy-map').readDurationMs, 0);
  });

  test('refreshHistoryInfo does not wait after final retry failure', () async {
    const sourceKey = 'history_refresh_test_source';
    var attempts = 0;
    final retryDelays = <Duration>[];
    final source = _source(
      sourceKey,
      loadComicInfo: (id) async {
        attempts++;
        return const Res.error('network unavailable');
      },
    );
    ComicSourceManager().add(source);
    addTearDown(() {
      ComicSourceManager().remove(sourceKey);
    });

    final history = History.fromMap({
      'type': ComicType.fromKey(sourceKey).value,
      'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'title': 'Remote Comic',
      'subtitle': 'Author',
      'cover': 'cover.jpg',
      'ep': 1,
      'page': 2,
      'id': 'comic-1',
      'readEpisode': ['1'],
      'max_page': 10,
    });

    final result = await HistoryManager.create().refreshHistoryInfo(
      history,
      retryDelay: (duration) {
        retryDelays.add(duration);
        return Future.value();
      },
    );

    expect(result, isFalse);
    expect(attempts, 3);
    expect(retryDelays, const [Duration(seconds: 2), Duration(seconds: 2)]);
  });

  test(
    'addHistoryAsync writes through an isolate-owned sqlite connection',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      await manager.addHistoryAsync(_history('comic-1'));

      final saved = manager.find('comic-1', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.page, 2);
      expect(saved.maxPage, 10);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'addHistoryAsync queues concurrent writes and updates cache',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final futures = List.generate(
        5,
        (index) => manager.addHistoryAsync(_history('comic-$index')),
      );
      await Future.wait(futures);

      expect(manager.count(), 5);
      for (var i = 0; i < 5; i++) {
        final saved = manager.find('comic-$i', ComicType.local);
        expect(saved, isNotNull);
        expect(saved!.title, 'Title comic-$i');
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'waitForAsyncWrites drains queued history writes before close',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final write = manager.addHistoryAsync(_history('comic-drained'));
      await manager.waitForAsyncWrites();
      await write;
      manager.close();
      HistoryManager.cache = null;

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final rows = db.select(
          'select page, max_page from history where id = ?',
          ['comic-drained'],
        );

        expect(rows, hasLength(1));
        expect(rows.first['page'], 2);
        expect(rows.first['max_page'], 10);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init migrates reading duration for an existing history database',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
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
          chapter_group int
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final saved = manager.find('legacy-comic', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.readDurationMs, 0);
      expect(manager.getTotalReadDurationMs(), 0);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'history writes support legacy tables without a unique id constraint',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
          id text,
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
          primary key (id, type)
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final existing = _history('legacy-comic')..page = 7;
      manager.addHistory(existing);
      await manager.addReadDuration(existing, const Duration(seconds: 15));
      await manager.addHistoryAsync(_history('new-comic'));
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final existingRows = db.select(
          '''
          select page, read_duration_ms
          from history where id = ? and type = ?;
          ''',
          ['legacy-comic', ComicType.local.value],
        );
        expect(existingRows, hasLength(1));
        expect(existingRows.first['page'], 7);
        expect(existingRows.first['read_duration_ms'], 15000);
        expect(db.select('select count(*) from history;').first[0], 2);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'reading duration accumulates and survives progress upserts',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final first = _history('comic-first');
      final second = _history('comic-second');
      manager.addHistory(first);
      manager.addHistory(second);

      await Future.wait([
        manager.addReadDuration(first, const Duration(seconds: 40)),
        manager.addReadDuration(first, const Duration(seconds: 20)),
        manager.addReadDuration(second, const Duration(seconds: 30)),
      ]);
      first.page = 8;
      first.maxPage = 12;
      await manager.addHistoryAsync(first);
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final row = db
            .select(
              '''
          select page, max_page, read_duration_ms
          from history where id = ?;
          ''',
              ['comic-first'],
            )
            .first;
        expect(row['page'], 8);
        expect(row['max_page'], 12);
        expect(row['read_duration_ms'], 60000);
      } finally {
        db.dispose();
      }

      expect(manager.getTotalReadDurationMs(), 90000);
      expect(manager.countWithReadDuration(), 2);
      expect(manager.getAllByReadDuration().map((history) => history.id), [
        'comic-first',
        'comic-second',
      ]);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

ComicSource _source(String key, {LoadComicFunc? loadComicInfo}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
