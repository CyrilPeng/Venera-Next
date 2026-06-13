import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

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
  test(
    'refresh task scheduler limits concurrency and throttles batches',
    () async {
      final started = <int>[];
      final completed = <int>[];
      final delays = <Duration>[];
      final blockers = <Completer<void>>[];
      var active = 0;
      var maxActive = 0;

      final runFuture = HistoryManager.debugRunThrottledRefreshTasks<int>(
        List.generate(6, (index) => index),
        concurrency: 3,
        throttleEvery: 3,
        delay: (duration) {
          delays.add(duration);
          return Future<void>.value();
        },
        run: (task) async {
          started.add(task);
          active++;
          if (active > maxActive) {
            maxActive = active;
          }
          final blocker = Completer<void>();
          blockers.add(blocker);
          await blocker.future;
          active--;
          completed.add(task);
        },
      );

      await pumpEventQueue();

      expect(started, [0, 1, 2]);
      expect(delays, [const Duration(seconds: 4)]);
      expect(maxActive, 3);

      for (final blocker in blockers.take(3)) {
        blocker.complete();
      }
      await pumpEventQueue();

      expect(started, [0, 1, 2, 3, 4, 5]);
      expect(delays, [const Duration(seconds: 4), const Duration(seconds: 7)]);
      expect(maxActive, 3);

      for (final blocker in blockers.skip(3)) {
        blocker.complete();
      }
      await runFuture;

      expect(completed, hasLength(6));
      expect(maxActive, 3);
    },
  );

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
}
