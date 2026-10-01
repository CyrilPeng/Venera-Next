import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
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
          manager.createFolder('original');
          manager.addComic('original', _item('old'));
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
              throwsA(isA<SqliteException>()),
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
