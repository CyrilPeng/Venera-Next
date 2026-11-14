import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'support/favorites_manager_fixture.dart';
import '../../support/sqlite_test_environment.dart';

void main() {
  test(
    'unavailable favorites query local existence only after admission',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('cleanup');
        await manager.addComic('cleanup', managerFavorite('present'));
        await manager.addComic('cleanup', managerFavorite('missing'));
        await manager.addComic(
          'cleanup',
          managerFavorite('remote')..type = const ComicType(987654321),
        );
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final checked = <String>[];
        final removing = manager.removeInvalid(
          localComicExists: (id) {
            checked.add(id);
            return id == 'present';
          },
        );
        expect(checked, isEmpty);
        expect(manager.count('cleanup'), 3);
        release.complete();
        await exclusive;
        expect(await removing, 2);
        expect(checked, unorderedEquals(['present', 'missing']));
        expect(manager.getFolderComics('cleanup').single.id, 'present');
      });
    },
  );

  test('local lookup failure reaches caller and cleanup can retry', () async {
    await withFavoritesManager((manager) async {
      await manager.createFolder('cleanup');
      await manager.addComic('cleanup', managerFavorite('missing'));
      final error = StateError('original local lookup failure');
      await expectLater(
        manager.removeInvalid(localComicExists: (_) => throw error),
        throwsA(same(error)),
      );
      expect(manager.count('cleanup'), 1);
      expect(await manager.removeInvalid(localComicExists: (_) => false), 1);
      expect(manager.count('cleanup'), 0);
    });
  });

  test(
    'favorite notifications cannot lend admission past a waiting replacement',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('notified');
        final events = <String>[];
        Future<void>? replacement;
        Future<bool>? later;
        var first = true;
        void changed() {
          if (!first) {
            events.add('later');
            return;
          }
          first = false;
          events.add('first');
          replacement = AppDataOperations.instance.run(() {
            events.add('replacement');
            expect(manager.count('notified'), 1);
          });
          later = manager.addComic('notified', managerFavorite('later'));
        }

        manager.addListener(changed);
        try {
          await manager.addComic('notified', managerFavorite('first'));
          await replacement;
          await later;
          expect(events, ['first', 'replacement', 'later']);
        } finally {
          manager.removeListener(changed);
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'exclusive reopen does not wait on initialization queued behind itself',
    () async {
      await withFavoritesManager((manager) async {
        await manager.closeAndWait();
        final release = Completer<void>();
        final reopening = AppDataOperations.instance.run(() async {
          await release.future;
          await manager.init();
        });
        final outside = manager.init();
        release.complete();
        await Future.wait([
          reopening,
          outside,
        ]).timeout(const Duration(seconds: 5));
        expect(
          manager.folderNames,
          contains(LocalFavoritesManager.trackingFolderName),
        );
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'same-path reopening rejects old source writes and ignores old publication',
    () async {
      await withFavoritesManager((manager) async {
        final generation = manager.connectionGeneration;
        final receipt = await manager.importNetworkFavorites(
          'old-network',
          'test',
          '',
          [managerFavorite('old')],
          oldToNew: false,
        );
        await manager.closeAndWait();
        await manager.init();
        await manager.deleteFolder('old-network');
        var notifications = 0;
        void changed() => notifications++;
        manager.addListener(changed);
        try {
          await manager.publishNetworkFavoriteImport(receipt);
          expect(notifications, 0);
          expect(manager.isExist('old', ComicType.local), isFalse);
          await expectLater(
            manager.updateInfo(
              'old-network',
              managerFavorite('late'),
              generation: generation,
            ),
            throwsStateError,
          );
          await expectLater(
            manager.importNetworkFavorites(
              'old-network',
              'test',
              '',
              [managerFavorite('late')],
              oldToNew: false,
              generation: generation,
            ),
            throwsStateError,
          );
          expect(manager.existsFolder('old-network'), isFalse);
        } finally {
          manager.removeListener(changed);
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'queued cancelled read does not mark a favorite as read',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final item = managerFavorite('unread');
        await manager.addComic(folder, item, null, 'old');
        await manager.updateUpdateTime(folder, item.id, item.type, 'new');
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        var cancelled = false;
        final failure = StateError('cancelled');
        final result = manager.onRead(
          item.id,
          item.type,
          checkActive: () {
            if (cancelled) throw failure;
          },
        );
        final expected = expectLater(result, throwsA(same(failure)));
        cancelled = true;
        release.complete();
        await Future.wait([exclusive, expected]);
        expect(manager.hasNewUpdate(item.id, item.type), isTrue);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'data replacement waits for admitted local imports and their favorite writes',
    () async {
      await withFavoritesManager((manager) async {
        final release = Completer<void>();
        final events = <String>[];
        final importing = LocalComicStorageGuard.instance.runImport(() async {
          await release.future;
          await manager.createFolder('imported');
          events.add('import');
        });
        final replacement = AppDataOperations.instance.run(() {
          events.add('replacement');
          expect(manager.existsFolder('imported'), isTrue);
        });
        release.complete();
        await Future.wait([
          importing,
          replacement,
        ]).timeout(const Duration(seconds: 5));
        expect(events, ['import', 'replacement']);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  for (final waitForClose in [false, true]) {
    test(
      'initialization completes after its hash publication; closing=$waitForClose',
      () async {
        await withFavoritesManager((manager) async {
          await manager.debugWaitForHashedIdsRefresh();
          var initReturned = false;
          var publishing = false;
          var publications = 0;
          final notificationSources = <bool>[];
          void changed() => notificationSources.add(publishing);
          manager.addListener(changed);
          try {
            Future<void>? readFailure;
            if (waitForClose) {
              readFailure = expectLater(
                manager.getAllComicsAsync(),
                completion(isEmpty),
              );
            }
            final closing = manager.closeAndWait();
            if (!waitForClose) await closing;
            final reopened = manager.init(
              publishChange: (notify) {
                expect(initReturned, isFalse);
                publications++;
                publishing = true;
                try {
                  notify();
                } finally {
                  publishing = false;
                }
              },
            );
            await closing;
            await readFailure;
            await reopened;
            initReturned = true;
            await manager.debugWaitForHashedIdsRefresh();
            expect(publications, 1);
            expect(notificationSources, [true]);
            expect(publishing, isFalse);

            // A subsequent local edit and unrelated refresh retain their normal
            // source; initialization does not install a manager-wide scope.
            notificationSources.clear();
            await manager.createFolder('local-after-import');
            expect(notificationSources, [false]);
            await manager.refreshHashedIds();
            expect(notificationSources, [false, false]);
            expect(publications, 1);
          } finally {
            manager.removeListener(changed);
          }
        });
      },
      skip: !sqliteTestAvailable(),
    );
  }

  test(
    'network refresh can recover after connection closure without reimport',
    () async {
      await withFavoritesManager((manager) async {
        final result = await manager.importNetworkFavorites(
          'Network',
          'test',
          'remote',
          [managerFavorite('persisted')],
          oldToNew: false,
        );
        await manager.closeAndWait();
        await expectLater(
          manager.publishNetworkFavoriteImport(result),
          throwsStateError,
        );
        expect(result.count, 1);
        await manager.init();
        await manager.debugWaitForHashedIdsRefresh();
        await manager.publishNetworkFavoriteImport(result);
        expect(manager.count('Network'), 1);
        expect(manager.folderComics('Network'), 1);
        expect(manager.isExist('persisted', ComicType.local), isTrue);
      });
    },
  );

  test(
    'close completes admitted readers before reopening and rejects closed reads',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('drain');
        await manager.addComic('drain', managerFavorite('old'));
        await manager.debugWaitForHashedIdsRefresh();
        final reads = [
          manager.getFolderComicsAsync('drain'),
          manager.getAllComicsAsync(),
          manager.getFolderComicsAsync('drain'),
        ];
        final completedReads = reads
            .map(
              (read) => expectLater(
                read.then((items) => items.map((item) => item.id).toList()),
                completion(['old']),
              ),
            )
            .toList();
        manager.refreshHashedIds();
        manager.refreshHashedIds();
        final closing = manager.closeAndWait();
        final closingAgain = manager.closeAndWait();
        expect(manager.totalComics, 1);
        await Future.wait([closing, closingAgain, ...completedReads]);
        expect(manager.totalComics, 0);
        final path = '${App.dataPath}/local_favorite.db';
        File(path).renameSync('$path.closed');
        await expectLater(
          manager.getFolderComicsAsync('drain'),
          throwsStateError,
        );
        await expectLater(manager.getAllComicsAsync(), throwsStateError);
        expect(File(path).existsSync(), isFalse);
        File('$path.closed').renameSync(path);
        await manager.init();
        expect((await manager.getFolderComicsAsync('drain')).single.id, 'old');
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test('initialization waits for draining readers', () async {
    await withFavoritesManager((manager) async {
      await manager.createFolder('drain-reopen');
      await manager.debugWaitForHashedIdsRefresh();
      final read = manager.getAllComicsAsync();
      final completedRead = expectLater(read, completion(isEmpty));
      final closing = manager.closeAndWait();
      final reopened = manager.init();
      await closing;
      await completedRead;
      await reopened;
      expect(manager.folderNames, contains('drain-reopen'));
    });
  }, skip: !sqliteTestAvailable());

  test(
    'clear shares one operation, drains readers and uses its owned path',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('clear-me');
        await manager.addComic('clear-me', managerFavorite('old'));
        await manager.debugWaitForHashedIdsRefresh();
        final ownedPath = App.dataPath;
        final other = Directory.systemTemp.createTempSync(
          'favorites-clear-other-',
        );
        final otherFile = File('${other.path}/local_favorite.db')
          ..writeAsStringSync('untouched');
        try {
          final reading = manager.getAllComicsAsync();
          final completedRead = expectLater(
            reading.then((items) => items.map((item) => item.id).toList()),
            completion(['old']),
          );
          App.dataPath = other.path;
          final clearing = manager.clearAll();
          expect(identical(clearing, manager.clearAll()), isTrue);
          await expectLater(manager.init(), throwsStateError);
          App.dataPath = ownedPath;
          final reopened = manager.init();
          await Future.wait([clearing, reopened, completedRead]);
          expect(manager.folderNames, [
            LocalFavoritesManager.trackingFolderName,
          ]);
          expect(manager.totalComics, 0);
          expect(otherFile.readAsStringSync(), 'untouched');
          expect(await manager.getAllComicsAsync(), isEmpty);
        } finally {
          App.dataPath = ownedPath;
          other.deleteSync(recursive: true);
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'initialization shares its connection and close is repeatable',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('lifecycle');
        final item = managerFavorite('kept');
        await manager.addComic('lifecycle', item);
        final ready = manager.init();
        final generation = manager.connectionGeneration;
        await Future.wait([ready, manager.init()]);
        expect(manager.connectionGeneration, generation);
        expect(manager.isExist(item.id, item.type), isTrue);
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        manager.close();
        expect(manager.totalComics, 0);
        expect(manager.counts, isEmpty);
        expect(() => manager.folderNames, throwsStateError);
        final first = manager.init();
        final second = manager.init();
        final openingGeneration = manager.connectionGeneration;
        await Future.wait([first, second]);
        expect(manager.connectionGeneration, openingGeneration);
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.isExist(item.id, item.type), isTrue);
        expect(manager.counts['lifecycle'], 1);
        manager.close();
        final finishing = manager.init();
        final finishingRead = expectLater(
          manager.debugWaitForHashedIdsRefresh(),
          throwsStateError,
        );
        final closed = expectLater(finishing, throwsStateError);
        manager.close();
        await closed;
        await finishingRead;
        await manager.init();
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'closed initialization cannot dispose a reopened connection',
    () async {
      await withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        appdata.settings['quickFavorite'] = 'missing-folder';
        final closing = manager.init();
        final failure = expectLater(closing, throwsStateError);
        manager.close();
        final reopened = manager.init();
        await failure;
        await reopened;
        await manager.createFolder('reopened');
        expect(manager.folderNames, contains('reopened'));
        final generation = manager.connectionGeneration;
        await manager.init();
        expect(manager.connectionGeneration, generation);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'ready manager rejects implicit data path switching',
    () async {
      await withFavoritesManager((manager) async {
        final originalPath = App.dataPath;
        final other = Directory.systemTemp.createTempSync('favorites-other-');
        try {
          App.dataPath = other.path;
          await expectLater(manager.init(), throwsStateError);
          expect(File('${other.path}/local_favorite.db').existsSync(), isFalse);
          expect(manager.folderNames, isNotEmpty);
        } finally {
          App.dataPath = originalPath;
          other.deleteSync(recursive: true);
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'isolate queries match synchronous folder order and aggregate identity',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('one');
        await manager.createFolder('two');
        await manager.addComic('one', managerFavorite('later'), 10);
        await manager.addComic('one', managerFavorite('first'), -5);
        await manager.addComic('two', managerFavorite('first'), 0);
        final syncFolder = manager.getFolderComics('one');
        final asyncFolder = await manager.getFolderComicsAsync('one');
        expect(
          asyncFolder.map((item) => item.toJson()),
          syncFolder.map((item) => item.toJson()),
        );
        expect(asyncFolder.map((item) => item.id), ['first', 'later']);
        expect(
          asyncFolder.map((item) => item.time),
          syncFolder.map((item) => item.time),
        );
        expect(
          (await manager.getAllComicsAsync()).map((item) => item.toJson()),
          manager.getAllComics().map((item) => item.toJson()),
        );
        expect(manager.getAllComics(), hasLength(2));
        expect(
          await manager.findWithModel(managerFavorite('first')),
          manager.find('first', ComicType.local),
        );
        expect(
          () => manager.getComic('one', 'missing', ComicType.local),
          throwsException,
        );
      });
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );
}
