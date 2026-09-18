import 'dart:io';

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
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    HistoryManager.cache = null;
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
    HistoryManager().addHistory(history);
  });
  tearDown(() {
    HistoryManager().close();
    HistoryManager.cache = null;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

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
