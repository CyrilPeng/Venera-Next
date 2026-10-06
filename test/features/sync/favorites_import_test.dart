import 'package:archive/archive.dart' as archive;
import 'dart:io';
import 'dart:async';
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
      LocalFavoritesManager.cache = null;
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
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousTracking;
        appdata.settings['quickFavorite'] = previousQuick;
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final corrupt in [false, true]) {
    test(
      'favorite database import replaces or rolls back with readers; corrupt=$corrupt',
      () async {
        final root = Directory.systemTemp.createTempSync('favorites-import-');
        final previousTracking = appdata.settings['followUpdatesFolder'];
        final previousQuick = appdata.settings['quickFavorite'];
        LocalFavoritesManager.cache = null;
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
            await expectLater(
              importAppData(File(archivePath)),
              throwsA(
                isA<DataSyncImportFailure>()
                    .having(
                      (error) => error.commitState,
                      'rollback outcome',
                      DataSyncCommitState.notApplied,
                    )
                    .having(
                      (error) => error.cause,
                      'original SQL error',
                      isA<SqliteException>(),
                    ),
              ),
            );
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
          LocalFavoritesManager.cache = null;
          appdata.settings['followUpdatesFolder'] = previousTracking;
          appdata.settings['quickFavorite'] = previousQuick;
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}
