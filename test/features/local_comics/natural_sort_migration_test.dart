import 'dart:io';
import 'dart:async';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late LocalManager local;
  late History history;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('natural-sort-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    await HistoryManager().init();
    local = LocalManager();
    await local.init();
    final folder = Directory('${local.path}/book')..createSync();
    for (final name in ['图片_1.jpg', '图片_10.jpg', '图片_2.jpg']) {
      File('${folder.path}/$name').writeAsBytesSync([1]);
    }
    final comic = LocalComic(
      id: '1',
      title: 'Book',
      subtitle: '',
      tags: [],
      directory: 'book',
      chapters: null,
      cover: '',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2026),
    );
    await local.add(comic);
    history = History.fromModel(model: comic, ep: 1, page: 2);
    await HistoryManager().addHistory(history);
  });
  tearDown(() {
    HistoryManager().close();
    LocalManager.current?.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'page-order conversion waits for exclusive storage before reading or writing',
    () async {
      final db = sqlite3.open('${root.path}/local.db');
      db.execute('DELETE FROM natural_sort_migration');
      final gate = Completer<void>();
      final exclusive = LocalComicStorageGuard.instance.runExclusive(
        () => gate.future,
      );
      final converting = local.migrateLegacyPageOrder(history);
      try {
        await pumpEventQueue();
        expect(history.page, 2);
        expect(db.select('SELECT * FROM natural_sort_migration'), isEmpty);
        gate.complete();
        await exclusive;
        await converting;
        expect(history.page, 3);
        expect(db.select('SELECT * FROM natural_sort_migration'), hasLength(1));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await exclusive;
        await converting;
        db.dispose();
      }
    },
  );

  test('concurrent conversions reuse the first mapping', () async {
    final db = sqlite3.open('${root.path}/local.db');
    db.execute('DELETE FROM natural_sort_migration');
    db.dispose();
    final second = history.copy();
    await Future.wait([
      local.migrateLegacyPageOrder(history),
      local.migrateLegacyPageOrder(second),
    ]);
    expect(history.page, 3);
    expect(second.page, 3);
    expect(HistoryManager().find('1', ComicType.local)!.page, 3);
  });

  test(
    'failed history write preserves mapping and permits same-object retry',
    () async {
      final localDb = sqlite3.open('${root.path}/local.db');
      localDb.execute('DELETE FROM natural_sort_migration');
      localDb.dispose();
      final historyDb = sqlite3.open('${root.path}/history.db');
      try {
        historyDb.execute(
          "CREATE TRIGGER reject_migration BEFORE UPDATE ON history BEGIN SELECT RAISE(ABORT, 'injected'); END;",
        );
        await expectLater(
          local.migrateLegacyPageOrder(history),
          throwsA(isA<SqliteException>()),
        );
        expect(history.page, 2);
        historyDb.execute('DROP TRIGGER reject_migration;');
        await local.migrateLegacyPageOrder(history);
        expect(history.page, 3);
        expect(HistoryManager().find('1', ComicType.local)!.page, 3);
      } finally {
        historyDb.dispose();
      }
    },
  );

  test('new imports retain their natural page number', () async {
    await local.migrateLegacyPageOrder(history);
    expect(history.page, 2);
    final images = await local.getImages('1', ComicType.local, 1);
    expect(images.map((p) => p.split(RegExp(r'[/\\]')).last), [
      '图片_1.jpg',
      '图片_2.jpg',
      '图片_10.jpg',
    ]);
  });

  test(
    'legacy progress preserves the image and migration is repeatable',
    () async {
      final db = sqlite3.open('${root.path}/local.db');
      db.execute('DELETE FROM natural_sort_migration');
      db.dispose();
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      expect(HistoryManager().find('1', ComicType.local)!.page, 3);
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      // Recover a mapping recorded before the history write completed.
      history.page = 2;
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      history.time = history.time.add(const Duration(seconds: 1));
      history.page = 2;
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 2);
    },
  );
}
