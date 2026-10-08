import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/history/history_retention_change.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

History _old(String id, int age) => History.fromMap({
  'id': id,
  'type': ComicType.local.value,
  'time': DateTime.now().subtract(Duration(days: age)).millisecondsSinceEpoch,
  'title': id,
  'subtitle': '',
  'cover': '',
  'ep': 1,
  'page': 1,
  'readEpisode': ['1'],
  'max_page': 1,
});

void main() {
  App.dataPath = App.cachePath = Directory.systemTemp.path;
  test(
    'shared save waits cleanup and retry retains cutoff and original failure',
    () async {
      final saved = Completer<void>();
      final deleting = Completer<void>();
      final failure = StateError('delete failed');
      final stack = StackTrace.current;
      var clock = DateTime(2026, 10, 8);
      final cutoffs = <int>[];
      var writes = 0;
      final change = HistoryRetentionChange(
        days: 7,
        access: (action) => action(),
        checkTarget: () {},
        saveDays: (days) async {
          expect(days, 7);
          writes++;
          await saved.future;
        },
        clearBefore: (cutoff) async {
          cutoffs.add(cutoff);
          if (cutoffs.length == 1) {
            await deleting.future;
            Error.throwWithStackTrace(failure, stack);
          }
        },
        now: () => clock,
      );
      final first = change.run();
      expect(change.run(), same(first));
      final observed = first.then<void>(
        (_) => fail('failure expected'),
        onError: (Object e, StackTrace s) {
          expect(e, same(failure));
          expect(s, same(stack));
        },
      );
      await pumpEventQueue();
      expect(cutoffs, isEmpty);
      saved.complete();
      await pumpEventQueue();
      expect(cutoffs, hasLength(1));
      var complete = false;
      observed.then((_) => complete = true);
      expect(complete, isFalse);
      deleting.complete();
      await observed;
      clock = clock.add(const Duration(days: 30));
      await change.run();
      expect(cutoffs, [
        DateTime(2026, 10, 1).millisecondsSinceEpoch,
        DateTime(2026, 10, 1).millisecondsSinceEpoch,
      ]);
      expect(writes, 2);
      await change.run();
      expect(writes, 2);
    },
  );

  group('real retention settings and SQLite', () {
    late Directory root;
    late HistoryManager manager;
    late AppdataImportCheckpoint checkpoint;
    late String previousPath, previousCache;
    setUp(() async {
      checkpoint = appdata.captureImportCheckpoint();
      previousPath = App.dataPath;
      previousCache = App.cachePath;
      root = Directory.systemTemp.createTempSync('history-retention-change-');
      App.dataPath = App.cachePath = root.path;
      appdata.settings['historyRetentionDays'] = 0;
      manager = HistoryManager.create();
      await manager.init();
    });
    tearDown(() async {
      await manager.waitForAsyncWrites();
      manager.close();
      await appdata.restoreImportCheckpoint(checkpoint, persist: false);
      App.dataPath = previousPath;
      App.cachePath = previousCache;
      root.deleteSync(recursive: true);
    });

    test(
      'retention above slider limit remains readable and does not shorten expiry',
      () async {
        await manager.addHistory(_old('keep-300', 300));
        await manager.addHistory(_old('remove-400', 400));
        manager.close();
        appdata.settings['historyRetentionDays'] = 365;
        await manager.init();
        expect(manager.find('keep-300', ComicType.local), isNotNull);
        expect(manager.find('remove-400', ComicType.local), isNull);
        expect(appdata.settings['historyRetentionDays'], 365);
      },
    );

    test(
      'failed settings persistence never starts cleanup and explicit retry repairs it',
      () async {
        await manager.addHistory(_old('old', 30));
        final blocked = Directory('${root.path}/appdata.json')..createSync();
        final change = manager.createRetentionChange(7);
        await expectLater(change.run(), throwsA(isA<FileSystemException>()));
        expect(manager.find('old', ComicType.local), isNotNull);
        blocked.deleteSync();
        await change.run();
        expect(manager.find('old', ComicType.local), isNull);
        expect(
          jsonDecode(
            File('${root.path}/appdata.json').readAsStringSync(),
          )['settings']['historyRetentionDays'],
          7,
        );
      },
    );

    test(
      'SQLite cleanup failure follows persisted choice and can be retried',
      () async {
        await manager.addHistory(_old('old', 30));
        manager.imageFavoritesDatabase.execute(
          "CREATE TRIGGER deny_retention BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'retention denied'); END;",
        );
        final change = manager.createRetentionChange(7);
        await expectLater(change.run(), throwsA(isA<SqliteException>()));
        expect(manager.find('old', ComicType.local), isNotNull);
        expect(
          jsonDecode(
            File('${root.path}/appdata.json').readAsStringSync(),
          )['settings']['historyRetentionDays'],
          7,
        );
        manager.imageFavoritesDatabase.execute('DROP TRIGGER deny_retention');
        await change.run();
        expect(manager.find('old', ComicType.local), isNull);
      },
    );

    test(
      'queued edit cannot save or clean a replacement history connection',
      () async {
        await manager.addHistory(_old('keep', 30));
        final change = manager.createRetentionChange(7);
        final replaced = Completer<void>();
        final release = Completer<void>();
        final replacement = AppDataOperations.instance.run(() async {
          manager.close();
          await manager.init();
          replaced.complete();
          await release.future;
        });
        await replaced.future;
        final result = expectLater(change.run(), throwsStateError);
        release.complete();
        await Future.wait([replacement, result]);
        expect(appdata.settings['historyRetentionDays'], 0);
        expect(manager.find('keep', ComicType.local), isNotNull);
        expect(File('${root.path}/appdata.json').existsSync(), isFalse);
      },
    );
  });
}
