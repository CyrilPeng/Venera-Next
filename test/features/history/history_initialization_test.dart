import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late Directory directory;
  late HistoryManager manager;
  late Object? previousRetention;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('history-initialization-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    previousRetention = appdata.settings['historyRetentionDays'];
    appdata.settings['historyRetentionDays'] = 0;
    manager = HistoryManager.create();
  });
  tearDown(() async {
    await manager.waitForAsyncWrites();
    manager.close();
    appdata.settings['historyRetentionDays'] = previousRetention;
    directory.deleteSync(recursive: true);
  });

  test(
    'concurrent callers and listener reentry share completed startup',
    () async {
      var notifications = 0;
      Future<void>? fromListener;
      manager.addListener(() {
        expect(manager.isInitialized, isTrue);
        expect(manager.count(), 0);
        fromListener = manager.init();
        notifications++;
      });
      final first = manager.init();
      expect(manager.init(), same(first));
      expect(manager.isInitialized, isFalse);
      expect(notifications, 0);
      await first;
      expect(fromListener, same(first));
      expect(notifications, 1);
      await manager.init();
      expect(notifications, 1);
    },
  );

  test(
    'independent manager initializes image tables on its own connection',
    () async {
      final unrelated = HistoryManager();
      try {
        await manager.init();
        expect(unrelated.isInitialized, isFalse);
        expect(
          manager.imageFavoritesDatabase.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'image_favorites'",
          ),
          hasLength(1),
        );
      } finally {
        unrelated.close();
      }
    },
  );

  test(
    'schema failure closes the connection and permits repaired retry',
    () async {
      final db = sqlite3.open('${directory.path}/history.db');
      db.execute('CREATE VIEW history AS SELECT 1 AS id');
      db.dispose();
      final failed = manager.init();
      expect(manager.init(), same(failed));
      await expectLater(failed, throwsA(isA<SqliteException>()));
      expect(manager.isInitialized, isFalse);
      expect(() => manager.imageFavoritesDatabase, throwsStateError);
      manager.close();
      manager.close();
      final repaired = sqlite3.open('${directory.path}/history.db');
      repaired.execute('DROP VIEW history');
      repaired.dispose();
      await manager.init();
      expect(manager.isInitialized, isTrue);
      expect(manager.count(), 0);
    },
  );

  test(
    'retention failure is shared and never publishes ready before retry',
    () async {
      final db = sqlite3.open('${directory.path}/history.db');
      HistoryRepository(db).initialize();
      db.execute("INSERT INTO history (id, time) VALUES ('expired', 0)");
      db.execute(
        "CREATE TRIGGER fail_retention BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'retention'); END",
      );
      db.dispose();
      appdata.settings['historyRetentionDays'] = 1;
      var notifications = 0;
      manager.addListener(() => notifications++);
      final first = manager.init();
      expect(manager.init(), same(first));
      await expectLater(first, throwsA(isA<SqliteException>()));
      expect(manager.isInitialized, isFalse);
      expect(notifications, 0);
      expect(() => manager.imageFavoritesDatabase, throwsStateError);
      final repaired = sqlite3.open('${directory.path}/history.db');
      expect(repaired.select('SELECT * FROM history'), hasLength(1));
      repaired.execute('DROP TRIGGER fail_retention');
      repaired.dispose();
      await manager.init();
      expect(manager.count(), 0);
      expect(notifications, 1);
    },
  );

  test(
    'closing during initialization cannot publish or close a replacement',
    () async {
      var notifications = 0;
      manager.addListener(() => notifications++);
      final old = manager.init();
      final oldFailure = expectLater(old, throwsStateError);
      manager.close();
      manager.close();
      final replacement = manager.init();
      expect(replacement, isNot(same(old)));
      await oldFailure;
      await replacement;
      expect(manager.isInitialized, isTrue);
      expect(manager.count(), 0);
      expect(notifications, 1);
    },
  );
}
