import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

History _history(String id) => History.fromMap({
  'type': ComicType.local.value,
  'time': DateTime(2026, 10, 5).millisecondsSinceEpoch,
  'title': 'Title $id',
  'subtitle': 'Author',
  'cover': 'cover.jpg',
  'ep': 1,
  'page': 2,
  'id': id,
  'readEpisode': ['1'],
  'max_page': 10,
});

void main() {
  late Directory directory;
  late HistoryManager manager;
  late AppDataOperations operations;
  late Object? previousRetention;
  Future<void> Function()? beforeDuration;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('history-admission-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    operations = AppDataOperations();
    previousRetention = appdata.settings['historyRetentionDays'];
    appdata.settings['historyRetentionDays'] = 0;
    beforeDuration = null;
    manager = HistoryManager.create(
      operations: operations,
      writeDuration: (path, snapshot, durationMs) async {
        await beforeDuration?.call();
        final database = sqlite3.open(path);
        try {
          HistoryRepository(database).addReadDuration(snapshot, durationMs);
        } finally {
          database.dispose();
        }
      },
    );
    await manager.init();
  });

  tearDown(() async {
    await manager.waitForAsyncWrites();
    manager.close();
    appdata.settings['historyRetentionDays'] = previousRetention;
    directory.deleteSync(recursive: true);
  });

  test(
    'reopening shares initialization with callers queued behind replacement',
    () async {
      final closed = Completer<void>();
      final release = Completer<void>();
      Future<void>? inside;
      var notifications = 0;
      manager.addListener(() => notifications++);
      final replacing = operations.run(() async {
        manager.close();
        closed.complete();
        await release.future;
        inside = manager.init();
        // Bounded failure also releases the exclusive owner in the regression.
        await inside!.timeout(const Duration(seconds: 2));
      });
      await closed.future;
      final outside = manager.init();
      expect(manager.init(), same(outside));
      release.complete();
      await Future.wait([outside, replacing]);
      expect(inside, same(outside));
      expect(manager.isInitialized, isTrue);
      expect(notifications, 1);
    },
  );

  test(
    'replacement drains accepted writes and late edits use the new database',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      beforeDuration = () async {
        started.complete();
        await release.future;
      };
      final original = _history('original');
      final staleMetadata = manager.metadataUpdaterFor(original);
      final duration = manager.addReadDuration(
        original,
        const Duration(milliseconds: 40),
      );
      final progress = manager.addHistory(original.copy()..page = 7);
      final events = <String>[];
      final replacement = operations.run(() async {
        expect(manager.find(original.id, original.type)!.readDurationMs, 40);
        expect(manager.find(original.id, original.type)!.page, 7);
        events.add('replacement');
        await manager.waitForAsyncWrites();
        manager.close();
        final target = Directory('${directory.path}/replacement')..createSync();
        App.dataPath = target.path;
        await manager.init();
        await manager.importHistory(original.copy()..title = 'Imported');
        await manager.importHistory(_history('remove'));
        await manager.waitForAsyncWrites();
      });
      final later = _history('later');
      final writingLater = manager.addHistory(later);
      later.id = 'mutated after submission';
      final deleting = manager.remove('remove', ComicType.local);
      final metadata = staleMetadata(title: 'Stale source');
      String? importPath;
      final importing = manager.importStorage((path) {
        importPath = path;
        final database = sqlite3.open(path);
        try {
          HistoryRepository(
            database,
          ).importHistory(_history('external import'));
        } finally {
          database.dispose();
        }
      }, onCommitted: () => events.add('external import'));
      await started.future;
      expect(events, isEmpty);
      release.complete();
      await Future.wait([
        duration,
        progress,
        replacement,
        writingLater,
        deleting,
        importing,
      ]);
      expect(await metadata, isFalse);
      expect(events, ['replacement', 'external import']);
      expect(importPath, '${directory.path}/replacement/history.db');
      expect(manager.find(original.id, original.type)!.title, 'Imported');
      expect(manager.find('later', ComicType.local), isNotNull);
      expect(manager.find(later.id, ComicType.local), isNull);
      expect(manager.find('remove', ComicType.local), isNull);
      expect(manager.find('external import', ComicType.local), isNotNull);
      final old = sqlite3.open('${directory.path}/history.db');
      try {
        final repository = HistoryRepository(old);
        expect(repository.count(), 1);
        expect(
          repository.find(original.id, original.type.value)!.readDurationMs,
          40,
        );
        expect(repository.find(original.id, original.type.value)!.page, 7);
      } finally {
        old.dispose();
      }
    },
  );

  test(
    'edits submitted while replacement has closed storage wait for reopening',
    () async {
      final closed = Completer<void>();
      final release = Completer<void>();
      final replacing = operations.run(() async {
        manager.close();
        closed.complete();
        await release.future;
        final target = Directory('${directory.path}/replacement')..createSync();
        App.dataPath = target.path;
        await manager.init();
        // Draining inside replacement must exclude edits waiting behind it.
        await manager.waitForAsyncWrites();
      });
      await closed.future;
      final item = _history('during replacement');
      final writing = manager.addReadDuration(
        item,
        const Duration(milliseconds: 30),
      );
      final progress = manager.addHistory(item.copy()..page = 9);
      release.complete();
      await Future.wait([replacing, writing, progress]);
      expect(manager.find(item.id, item.type)!.page, 9);
      expect(manager.find(item.id, item.type)!.readDurationMs, 30);
      expect(item.readDurationMs, 30);
    },
  );

  test(
    'completion listeners start independent replacements and writes',
    () async {
      final events = <String>[];
      Future<void>? replacing;
      Future<void>? following;
      void listener() {
        manager.removeListener(listener);
        replacing = operations.run(() async {
          events.add('replacement');
          await manager.waitForAsyncWrites();
          manager.close();
          final target = Directory('${directory.path}/replacement')
            ..createSync();
          App.dataPath = target.path;
          await manager.init();
        });
        following = manager.addHistory(_history('listener'));
        events.add('listener returned');
      }

      manager.addListener(listener);
      await manager.addHistory(_history('first'));
      await replacing;
      await following;
      expect(events, ['listener returned', 'replacement']);
      expect(manager.find('first', ComicType.local), isNull);
      expect(manager.find('listener', ComicType.local), isNotNull);
    },
  );

  test(
    'initialization listeners cannot borrow the importing operation',
    () async {
      manager.close();
      final events = <String>[];
      Future<void>? fromListener;
      void listener() {
        manager.removeListener(listener);
        fromListener = operations.run(() => events.add('listener replacement'));
        events.add('notification');
      }

      manager.addListener(listener);
      await operations.run(() async {
        await manager.init();
        await manager.waitForAsyncWrites();
        expect(events, ['notification']);
        events.add('import finished');
      });
      await fromListener;
      expect(events, [
        'notification',
        'import finished',
        'listener replacement',
      ]);
    },
  );

  test(
    'external commit callback publishes before its own queued replacement',
    () async {
      final events = <String>[];
      Future<void>? fromCallback;
      await manager.importStorage(
        (path) {
          final database = sqlite3.open(path);
          try {
            HistoryRepository(database).importHistory(_history('external'));
          } finally {
            database.dispose();
          }
        },
        onCommitted: () {
          expect(manager.find('external', ComicType.local), isNotNull);
          fromCallback = operations.run(() => events.add('replacement'));
          events.add('published');
        },
      );
      await fromCallback;
      expect(events, ['published', 'replacement']);
    },
  );
}
