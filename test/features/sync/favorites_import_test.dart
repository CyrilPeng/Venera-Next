import 'package:archive/archive.dart' as archive;
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:venera_next/foundation/app_data_operations.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

import '../../support/legacy_favorites_fixture.dart';
import '../../support/zip_fixture.dart';

FavoriteItem _item(String id) => FavoriteItem(
  id: id,
  name: id,
  author: '',
  coverPath: '',
  type: ComicType.local,
  tags: [],
);

void main() {
  test(
    'import, export and queued clear keep archives isolated and avoid deadlock',
    () async {
      final root = Directory.systemTemp.createTempSync('app-data-queue-');
      final previousTracking = appdata.settings['followUpdatesFolder'];
      final previousQuick = appdata.settings['quickFavorite'];
      final manager = LocalFavoritesManager();
      final release = Completer<void>();
      try {
        App.dataPath = (Directory('${root.path}/data')..createSync()).path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        Directory('${App.dataPath}/comic_source').createSync();
        for (final name in ['history.db', 'cookie.db']) {
          final db = sqlite3.open('${App.dataPath}/$name');
          db.execute('CREATE TABLE seed (id INT);');
          db.dispose();
        }
        await manager.init();
        await manager.createFolder('original');
        await manager.addComic('original', _item('old'));
        await appdata.saveData(false);
        final incomingPath = '${root.path}/incoming.db';
        final incoming = sqlite3.open(incomingPath);
        final repository = FavoritesRepository(incoming);
        repository.initializeMetadata();
        repository.createFolder('imported');
        repository.addComic(
          'imported',
          _item('new'),
          translatedTags: '',
          append: true,
        );
        incoming.dispose();
        final source = File('${root.path}/incoming.venera');
        final zip = ZipFile.open(source.path);
        zip.addFile('local_favorite.db', incomingPath);
        zip.close();
        final entered = Completer<void>();
        final held = AppDataOperations.instance.run(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final imported = importAppData(source);
        final exportBefore = exportAppData(sync: false);
        final cleared = manager.clearAll();
        final exportAfter = exportAppData(sync: false);
        final beforeRelease = manager.getFolderComics('original').single.id;
        release.complete();
        await held;
        await imported;
        final before = await exportBefore;
        final beforeBytes = before.readAsBytesSync();
        await cleared;
        final after = await exportAfter;
        expect(beforeRelease, 'old');
        expect(before.path, isNot(after.path));
        expect(before.readAsBytesSync(), beforeBytes);
        final beforeDir = Directory('${root.path}/before')..createSync();
        final afterDir = Directory('${root.path}/after')..createSync();
        for (final (file, directory) in [
          (before, beforeDir),
          (after, afterDir),
        ]) {
          final decoded = archive.ZipDecoder().decodeBytes(
            file.readAsBytesSync(),
          );
          File(
            '${directory.path}/local_favorite.db',
          ).writeAsBytesSync(decoded.findFile('local_favorite.db')!.content);
        }
        final beforeDb = sqlite3.open('${beforeDir.path}/local_favorite.db');
        final afterDb = sqlite3.open('${afterDir.path}/local_favorite.db');
        try {
          expect(
            FavoritesRepository(beforeDb).getFolderComics('imported').single.id,
            'new',
          );
          expect(FavoritesRepository(afterDb).folderNames(), [
            LocalFavoritesManager.trackingFolderName,
          ]);
          expect(
            FavoritesRepository(
              afterDb,
            ).count(LocalFavoritesManager.trackingFolderName),
            0,
          );
        } finally {
          beforeDb.dispose();
          afterDb.dispose();
        }
        Directory('${App.dataPath}/comic_source').deleteSync();
        await expectLater(
          exportAppData(sync: false),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          Directory(
            App.cachePath,
          ).listSync().where((entry) => entry.path.endsWith('.venera')),
          hasLength(2),
        );
        Directory('${App.dataPath}/comic_source').createSync();
        expect((await exportAppData(sync: false)).existsSync(), isTrue);
        final invalid = File('${root.path}/invalid.venera');
        final invalidArchive = archive.Archive()
          ..addFile(archive.ArchiveFile.string('../escaped', 'invalid'));
        invalid.writeAsBytesSync(archive.ZipEncoder().encode(invalidArchive));
        await expectLater(importAppData(invalid), throwsFormatException);
        await expectLater(importPicaData(invalid), throwsFormatException);
        expect(File('${App.cachePath}/escaped').existsSync(), isFalse);
        expect(manager.getAllComics(), isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await AppDataOperations.instance.run(() async {});
        await manager.closeAndWait();
        await appdata.saveData(false);
        appdata.settings['followUpdatesFolder'] = previousTracking;
        appdata.settings['quickFavorite'] = previousQuick;
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'analyzed legacy favorites import from a backup and reopen intact',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'analyzed-favorites-import-',
      );
      final checkpoint = appdata.captureImportCheckpoint();
      final manager = LocalFavoritesManager();
      try {
        App.dataPath = (Directory('${root.path}/data')..createSync()).path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        await manager.init();
        await manager.createFolder('original');
        await manager.addComic('original', _item('old'));
        final incomingPath = '${root.path}/incoming.db';
        final incoming = sqlite3.open(incomingPath);
        late Map<String, Object?> internalBefore;
        try {
          seedAnalyzedLegacyFavorites(incoming);
          // Other SQLite internals must survive hierarchy metadata replacement.
          internalBefore = sqliteInternalTableSnapshot(
            incoming,
            excludeStatisticsFor: {'folder_order'},
          );
        } finally {
          incoming.dispose();
        }
        final settings =
            jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
        (settings['settings'] as Map<String, dynamic>)
          ..['followUpdatesFolder'] = 'sqliteXnotes'
          ..['quickFavorite'] = 'legacy';
        final settingsFile = File('${root.path}/incoming.json')
          ..writeAsStringSync(jsonEncode(settings));
        final source = File('${root.path}/data.venera');
        final zip = ZipFile.open(source.path);
        zip.addFile('local_favorite.db', incomingPath);
        zip.addFile('appdata.json', settingsFile.path);
        zip.close();

        expect(await importAppData(source), DataSyncCommitState.applied);
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(manager.folderNames, ['sqliteXnotes', 'legacy']);
          expect(manager.counts, {'sqliteXnotes': 1, 'legacy': 1});
          expect(manager.totalComics, 2);
          expect(manager.isExist('legacy-id', ComicType.local), isTrue);
          expect(manager.isExist('old', ComicType.local), isFalse);
          final tracked = manager
              .getComicsWithUpdatesInfo('sqliteXnotes')
              .single;
          expect(tracked.hasNewUpdate, isTrue);
          expect(tracked.updateTime, 'chapter 2');
          expect(tracked.lastCheckTime!.millisecondsSinceEpoch, 123);
          // Import applies folder settings after reopening the store; check
          // persisted fields above and the selected-folder cache after restart.
          if (attempt > 0) {
            expect(manager.hasNewUpdate('modern-id', ComicType.local), isTrue);
          }
          expect(manager.findLinked('legacy'), (
            'fixture-source',
            'remote-folder',
          ));
          expect(appdata.settings['followUpdatesFolder'], 'sqliteXnotes');
          expect(appdata.settings['quickFavorite'], 'legacy');
          final legacy = (await manager.getFolderComicsAsync('legacy')).single;
          expect(legacy.name, 'Legacy favorite');
          expect(legacy.tags, ['tag', 'second']);
          expect(legacy.time, '2001-02-03 04:05:06');
          expect(manager.search('preserved').single.id, 'modern-id');
          final persisted = sqlite3.open(
            manager.databasePath,
            mode: OpenMode.readOnly,
          );
          try {
            expect(sqliteInternalTableSnapshot(persisted), internalBefore);
            expect(
              persisted.select('PRAGMA quick_check;').single['quick_check'],
              'ok',
            );
          } finally {
            persisted.dispose();
          }
          await manager.closeAndWait();
          if (attempt == 0) await manager.init();
        }
      } finally {
        await manager.closeAndWait();
        await appdata.restoreImportCheckpoint(checkpoint, persist: false);
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final corrupt in [false, true]) {
    test(
      'favorite database import replaces or rejects before mutation with readers; corrupt=$corrupt',
      () async {
        final root = Directory.systemTemp.createTempSync('favorites-import-');
        final previousTracking = appdata.settings['followUpdatesFolder'];
        final previousQuick = appdata.settings['quickFavorite'];
        final manager = LocalFavoritesManager();
        try {
          App.dataPath = (Directory('${root.path}/data')..createSync()).path;
          App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
          await manager.init();
          await manager.createFolder('original');
          await manager.addComic('original', _item('old'));
          final incomingPath = '${root.path}/incoming.db';
          if (corrupt) {
            File(incomingPath).writeAsBytesSync(List.filled(4096, 42));
          } else {
            final incoming = sqlite3.open(incomingPath);
            try {
              final repository = FavoritesRepository(incoming);
              repository.initializeMetadata();
              repository.createFolder('imported');
              repository.addComic(
                'imported',
                _item('new'),
                translatedTags: '',
                append: true,
              );
            } finally {
              incoming.dispose();
            }
          }
          final archivePath = '${root.path}/import.venera';
          final zip = ZipFile.open(archivePath);
          zip.addFile('local_favorite.db', incomingPath);
          zip.close();
          final reads = <Future<void>>[
            for (var i = 0; i < 3; i++)
              manager.getAllComicsAsync().then<void>(
                (_) {},
                onError: (Object error, StackTrace stack) {
                  expect(error, isA<StateError>());
                },
              ),
          ];
          if (corrupt) {
            final generation = manager.connectionGeneration;
            final bytes = File(manager.databasePath).readAsBytesSync();
            final settings = jsonEncode(appdata.toJson());
            await expectLater(
              importAppData(File(archivePath)),
              throwsA(isA<SqliteException>()),
            );
            expect(manager.connectionGeneration, generation);
            expect(File(manager.databasePath).readAsBytesSync(), bytes);
            expect(jsonEncode(appdata.toJson()), settings);
            expect(manager.getFolderComics('original').single.id, 'old');
          } else {
            await importAppData(File(archivePath));
            expect(manager.folderNames, ['imported']);
            expect(manager.getFolderComics('imported').single.id, 'new');
          }
          await Future.wait(reads);
          await manager.closeAndWait();
          final path = '${App.dataPath}/local_favorite.db';
          File(path).renameSync('$path.checked');
          File('$path.checked').renameSync(path);
          await manager.init();
          expect(manager.getAllComics().single.id, corrupt ? 'old' : 'new');
        } finally {
          await manager.closeAndWait();
          await appdata.saveData(false);
          appdata.settings['followUpdatesFolder'] = previousTracking;
          appdata.settings['quickFavorite'] = previousQuick;
          root.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final sync in [false, true]) {
    for (final damage in ZipFixtureDamage.values) {
      test(
        'damaged ZIP preserves live favorites and settings; sync=$sync damage=$damage',
        () async {
          final root = Directory.systemTemp.createTempSync(
            'damaged-favorites-',
          );
          final checkpoint = appdata.captureImportCheckpoint();
          final manager = LocalFavoritesManager();
          try {
            App.dataPath = (Directory('${root.path}/data')..createSync()).path;
            App.cachePath = (Directory(
              '${root.path}/cache',
            )..createSync()).path;
            await manager.init();
            await manager.createFolder('original');
            await manager.addComic('original', _item('old'));
            await manager.debugWaitForHashedIdsRefresh();
            await appdata.saveData(false);
            final generation = manager.connectionGeneration;
            final before = File(manager.databasePath).readAsBytesSync();
            final settings = jsonEncode(appdata.toJson());
            final savedSettings = File(
              '${App.dataPath}/appdata.json',
            ).readAsBytesSync();
            final incomingPath = '${root.path}/incoming.db';
            final incoming = sqlite3.open(incomingPath);
            try {
              final repository = FavoritesRepository(incoming)
                ..initializeMetadata();
              repository.createFolder('imported');
              repository.addComic(
                'imported',
                _item('new'),
                translatedTags: '',
                append: true,
              );
            } finally {
              incoming.dispose();
            }
            final entries = [
              ZipFixtureEntry(
                utf8.encode('appdata.json'),
                utf8.encode(
                  jsonEncode({
                    'settings': {'language': 'ja-JP'},
                    'searchHistory': ['incoming'],
                  }),
                ),
              ),
              ZipFixtureEntry(
                utf8.encode('local_favorite.db'),
                File(incomingPath).readAsBytesSync(),
              ),
            ];
            final source = File('${root.path}/incoming.venera')
              ..writeAsBytesSync(zipFixture(entries, damage: damage));
            Future<DataSyncCommitState> restore() => sync
                ? importSyncAppData(source, checkActive: () {})
                : importAppData(source);

            await expectLater(restore(), throwsFormatException);
            expect(manager.connectionGeneration, generation);
            expect(File(manager.databasePath).readAsBytesSync(), before);
            expect(jsonEncode(appdata.toJson()), settings);
            expect(
              File('${App.dataPath}/appdata.json').readAsBytesSync(),
              savedSettings,
            );
            expect(manager.getFolderComics('original').single.id, 'old');
            expect(Directory(App.cachePath).listSync(), isEmpty);

            source.writeAsBytesSync(zipFixture(entries));
            expect(await restore(), DataSyncCommitState.applied);
            expect(manager.getFolderComics('imported').single.id, 'new');
            expect(manager.isExist('old', ComicType.local), isFalse);
            expect(appdata.searchHistory, ['incoming']);
          } finally {
            await AppDataOperations.instance.run(() async {});
            await manager.closeAndWait();
            await appdata.restoreImportCheckpoint(checkpoint, persist: false);
            root.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
