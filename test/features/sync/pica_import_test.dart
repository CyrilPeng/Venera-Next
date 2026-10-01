import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test(
    'legacy archive imports integer history chapters and keeps existing links',
    () async {
      final root = Directory.systemTemp.createTempSync('pica-import-');
      final previousTracking = appdata.settings['followUpdatesFolder'];
      final previousQuick = appdata.settings['quickFavorite'];
      LocalFavoritesManager.cache = null;
      HistoryManager.cache = null;
      final favorites = LocalFavoritesManager();
      final history = HistoryManager();
      try {
        App.dataPath = (Directory('${root.path}/data')..createSync()).path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        await favorites.init();
        await history.init();
        final favoritePath = '${root.path}/favorites.db';
        final legacyFavorites = sqlite3.open(favoritePath);
        try {
          legacyFavorites.execute('CREATE TABLE folder_order (name TEXT);');
          legacyFavorites.execute(
            'CREATE TABLE folder_sync (folder_name TEXT, key TEXT, sync_data TEXT);',
          );
          legacyFavorites.execute(
            'CREATE TABLE "旧收藏 ""A""" (target TEXT, type INT, name TEXT, author TEXT, cover_path TEXT, tags TEXT);',
          );
          legacyFavorites.execute(
            'INSERT INTO "旧收藏 ""A""" VALUES (?, 0, ?, ?, ?, ?);',
            ['favorite-id', 'title', 'author', 'cover', 'a,b'],
          );
          legacyFavorites.execute('INSERT INTO folder_sync VALUES (?, ?, ?);', [
            '旧收藏 "A"',
            'HtManga',
            '{"folderId":"remote"}',
          ]);
        } finally {
          legacyFavorites.dispose();
        }
        final historyPath = '${root.path}/history.db';
        final legacyHistory = sqlite3.open(historyPath);
        try {
          legacyHistory.execute(
            'CREATE TABLE history (target TEXT, type INT, max_page INT, ep INT, page INT, time INT, title TEXT, subtitle TEXT, cover TEXT);',
          );
          legacyHistory.execute(
            'INSERT INTO history VALUES (?, 5, 20, 2, 7, ?, ?, ?, ?);',
            [
              'history-id',
              DateTime.now().millisecondsSinceEpoch,
              'history title',
              'author',
              'cover',
            ],
          );
          legacyHistory.execute(
            'CREATE TABLE image_favorites (id TEXT, ep INT, page INT, title TEXT);',
          );
        } finally {
          legacyHistory.dispose();
        }
        final package = File('${root.path}/legacy.picadata');
        void writePackage() {
          final archive = Archive();
          for (final (name, path) in [
            ('local_favorite.db', favoritePath),
            ('history.db', historyPath),
          ]) {
            final bytes = File(path).readAsBytesSync();
            archive.addFile(ArchiveFile(name, bytes.length, bytes));
          }
          package.writeAsBytesSync(ZipEncoder().encode(archive));
        }

        writePackage();
        await importPicaData(package);
        expect(
          favorites.getFolderComics('旧收藏 "A"').single.type.value,
          'picacg'.hashCode,
        );
        expect(favorites.findLinked('旧收藏 "A"'), ('wnacg', 'remote'));
        final imported = history.find(
          'history-id',
          ComicType('nhentai'.hashCode),
        );
        expect(imported, isNotNull);
        expect(imported!.page, 7);
        expect(imported.readEpisode, {'2'});
        final invalidLink = sqlite3.open(favoritePath);
        invalidLink.execute(
          "UPDATE folder_sync SET sync_data = 'invalid json';",
        );
        invalidLink.dispose();
        writePackage();
        await importPicaData(package);
        expect(favorites.getFolderComics('旧收藏 "A"'), hasLength(1));
        expect(favorites.findLinked('旧收藏 "A"'), ('wnacg', 'remote'));
        expect(history.count(), 1);
        expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
      } finally {
        await history.waitForAsyncWrites();
        if (history.isInitialized) history.close();
        await favorites.closeAndWait();
        await appdata.saveData(false);
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousTracking;
        appdata.settings['quickFavorite'] = previousQuick;
        root.deleteSync(recursive: true);
      }
    },
  );
  test('invalid late source records fail before any destination writes', () async {
    final root = Directory.systemTemp.createTempSync('pica-preflight-');
    final previousTracking = appdata.settings['followUpdatesFolder'];
    final previousQuick = appdata.settings['quickFavorite'];
    LocalFavoritesManager.cache = null;
    HistoryManager.cache = null;
    final favorites = LocalFavoritesManager();
    final history = HistoryManager();
    var notifications = 0;
    void changed() => notifications++;
    try {
      App.dataPath = (Directory('${root.path}/data')..createSync()).path;
      App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
      await favorites.init();
      await history.init();
      favorites.createFolder('existing');
      favorites.addComic(
        'existing',
        FavoriteItem(
          id: 'keep',
          name: 'original',
          coverPath: '',
          author: '',
          type: ComicType('picacg'.hashCode),
          tags: [],
        ),
      );
      await favorites.debugWaitForHashedIdsRefresh();
      favorites.addListener(changed);
      history.addListener(changed);
      final source = sqlite3.open('${root.path}/source.db');
      try {
        source.execute(
          'CREATE TABLE folder_sync (folder_name TEXT, key TEXT, sync_data TEXT);',
        );
        source.execute(
          'CREATE TABLE imported (target TEXT, type INT, name TEXT, author TEXT, cover_path TEXT, tags TEXT);',
        );
        source.execute(
          "INSERT INTO imported VALUES ('new', 0, 'new title', '', '', '');",
        );
        source.execute(
          "INSERT INTO imported VALUES ('bad', 0, 'bad title', '', '', NULL);",
        );
      } finally {
        source.dispose();
      }
      final legacyHistory = sqlite3.open('${root.path}/history.db');
      try {
        legacyHistory.execute(
          'CREATE TABLE history (target TEXT, type INT, max_page INT, ep INT, page INT, time INT, title TEXT, subtitle TEXT, cover TEXT);',
        );
        legacyHistory.execute(
          "INSERT INTO history VALUES ('new-history', 0, 10, 'invalid', 2, 1234, 'title', '', '');",
        );
        legacyHistory.execute(
          'CREATE TABLE image_favorites (id TEXT, ep INT, page INT, title TEXT);',
        );
        legacyHistory.execute(
          "INSERT INTO image_favorites VALUES (NULL, 1, 1, 'invalid image');",
        );
      } finally {
        legacyHistory.dispose();
      }
      final package = File('${root.path}/legacy.picadata');
      void writePackage() {
        final archive = Archive();
        for (final (name, path) in [
          ('local_favorite.db', '${root.path}/source.db'),
          ('history.db', '${root.path}/history.db'),
        ]) {
          final bytes = File(path).readAsBytesSync();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        package.writeAsBytesSync(ZipEncoder().encode(archive));
      }

      Future<void> expectUnchanged() async {
        writePackage();
        await expectLater(importPicaData(package), throwsA(isA<TypeError>()));
        expect(favorites.existsFolder('imported'), isFalse);
        expect(favorites.getFolderComics('existing').single.id, 'keep');
        expect(history.count(), 0);
        expect(notifications, 0);
        expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
      }

      await expectUnchanged();
      final repairFavorites = sqlite3.open('${root.path}/source.db');
      try {
        repairFavorites.execute("DELETE FROM imported WHERE target = 'bad';");
      } finally {
        repairFavorites.dispose();
      }
      await expectUnchanged();
      final repairHistory = sqlite3.open('${root.path}/history.db');
      try {
        repairHistory.execute('UPDATE history SET ep = 1;');
      } finally {
        repairHistory.dispose();
      }
      await expectUnchanged();
      final repairImages = sqlite3.open('${root.path}/history.db');
      try {
        repairImages.execute('DELETE FROM image_favorites;');
      } finally {
        repairImages.dispose();
      }
      writePackage();
      await importPicaData(package);
      expect(favorites.getFolderComics('imported').single.id, 'new');
      expect(favorites.getFolderComics('existing').single.id, 'keep');
      expect(history.count(), 1);
      expect(notifications, greaterThan(0));
    } finally {
      favorites.removeListener(changed);
      history.removeListener(changed);
      await history.waitForAsyncWrites();
      if (history.isInitialized) history.close();
      await favorites.closeAndWait();
      await appdata.saveData(false);
      HistoryManager.cache = null;
      LocalFavoritesManager.cache = null;
      appdata.settings['followUpdatesFolder'] = previousTracking;
      appdata.settings['quickFavorite'] = previousQuick;
      root.deleteSync(recursive: true);
    }
  });
}
