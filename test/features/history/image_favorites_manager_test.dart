import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'image_favorites_repository_test.dart' show comic;

void main() {
  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });
  test(
    'failed batch delete retains rows and cache without notifying; retry commits',
    () async {
      final root = Directory.systemTemp.createTempSync('image-favorites-');
      final previousData = App.dataPath;
      final previousCache = App.cachePath;
      final previousManager = HistoryManager.cache;
      final history = HistoryManager.create();
      HistoryManager.cache = history;
      final manager = ImageFavoriteManager();
      var notifications = 0;
      void changed() {
        notifications++;
        expect(manager.length, 0);
      }

      try {
        App.dataPath = root.path;
        App.cachePath = root.path;
        await history.init();
        final first = comic('first');
        final second = comic('second');
        manager.addOrUpdateOrDelete(first);
        manager.addOrUpdateOrDelete(second);
        final provider = ImageFavoritesProvider(first.images.single);
        await provider.writeToCache(Uint8List.fromList([1, 2, 3]));
        final db = history.imageFavoritesDatabase;
        db.execute(
          "CREATE TRIGGER fail_delete BEFORE DELETE ON image_favorites WHEN old.id = 'second' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
        );
        manager.addListener(changed);
        expect(
          () =>
              manager.deleteImageFavorite([...first.images, ...second.images]),
          throwsA(isA<SqliteException>()),
        );
        expect(manager.length, 2);
        expect(manager.find('first', 'source')!.images, hasLength(1));
        expect(await provider.readFromCache(), [1, 2, 3]);
        expect(notifications, 0);
        db.execute('DROP TRIGGER fail_delete;');
        manager.deleteImageFavorite([...first.images, ...second.images]);
        expect(notifications, 1);
        // The public delete API remains synchronous; its cache cleanup is async.
        for (var attempt = 0; attempt < 50; attempt++) {
          if (await provider.readFromCache() == null) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await provider.readFromCache(), isNull);
      } finally {
        manager.removeListener(changed);
        await history.waitForAsyncWrites();
        if (history.isInitialized) history.close();
        HistoryManager.cache = previousManager;
        App.dataPath = previousData;
        App.cachePath = previousCache;
        root.deleteSync(recursive: true);
      }
    },
  );

  test('cache deletion uses the same full identity as cache writes', () async {
    final root = Directory.systemTemp.createTempSync('image-cache-');
    final previousCache = App.cachePath;
    try {
      App.cachePath = root.path;
      final a = ImageFavoritesProvider(comic('shared').images.single);
      final b = ImageFavoritesProvider(
        comic('shared', source: 'other').images.single,
      );
      await a.writeToCache(Uint8List.fromList([1]));
      await b.writeToCache(Uint8List.fromList([2]));
      await ImageFavoritesProvider.deleteFromCache(a.imageFavorite);
      expect(await a.readFromCache(), isNull);
      expect(await b.readFromCache(), [2]);
    } finally {
      App.cachePath = previousCache;
      root.deleteSync(recursive: true);
    }
  });
}
