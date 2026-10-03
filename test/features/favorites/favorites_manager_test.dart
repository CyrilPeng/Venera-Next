import 'dart:convert';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';

FavoriteItem _favorite(String id) {
  return FavoriteItem(
    id: id,
    name: 'Comic $id',
    coverPath: 'cover-$id.jpg',
    author: 'Author',
    type: ComicType.local,
    tags: const ['tag'],
  );
}

// Exercise publication of a committed external deletion independently of the
// local/history coordinator, including no-op and failure-before-publication.
void _deleteExternally(LocalFavoritesManager manager, List<ComicID> comics) {
  final db = sqlite3.open(manager.databasePath);
  try {
    final removed = FavoritesRepository(db).deleteComics(
      manager.folderNames,
      comics.map((comic) => (comic.id, comic.type.value)),
    );
    manager.refreshDeletedFavorites(removed);
  } finally {
    db.dispose();
  }
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _withFavoritesManager(
  Future<void> Function(LocalFavoritesManager manager) run,
) async {
  final dataDir = Directory.systemTemp.createTempSync('venera-favorites-data-');
  final cacheDir = Directory.systemTemp.createTempSync(
    'venera-favorites-cache-',
  );
  final previousFollowUpdatesFolder = appdata.settings['followUpdatesFolder'];
  final previousQuickFavorite = appdata.settings['quickFavorite'];
  LocalFavoritesManager? manager;
  try {
    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
    LocalFavoritesManager.cache = null;

    manager = LocalFavoritesManager();
    await manager.init();
    await run(manager);
    await appdata.saveData(false);
  } finally {
    if (manager != null) {
      await manager.debugWaitForHashedIdsRefresh();
      try {
        await manager.closeAndWait();
      } catch (_) {
        // ignore cleanup failures in partially initialized tests
      }
    }
    LocalFavoritesManager.cache = null;
    appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
    appdata.settings['quickFavorite'] = previousQuickFavorite;
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
    if (cacheDir.existsSync()) {
      cacheDir.deleteSync(recursive: true);
    }
  }
}

void main() {
  test(
    'folder JSON import publishes complete counts once and malformed input not at all',
    () async {
      await _withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        var notifications = 0;
        void changed() {
          notifications++;
          expect(manager.folderComics('JSON import'), 2);
          expect(manager.isExist('json-a', const ComicType(17)), isTrue);
          expect(manager.isExist('json-b', const ComicType(17)), isTrue);
        }

        manager.addListener(changed);
        try {
          final a = _favorite('json-a')..type = const ComicType(17);
          final b = _favorite('json-b')..type = const ComicType(17);
          expect(
            () => manager.fromJson(
              jsonEncode({
                'name': 'JSON import',
                'comics': [
                  a.toJson(),
                  {'name': 'bad'},
                ],
              }),
            ),
            throwsA(isA<TypeError>()),
          );
          expect(manager.existsFolder('JSON import'), isFalse);
          expect(notifications, 0);
          manager.fromJson(
            jsonEncode({
              'name': 'JSON import',
              'comics': [a.toJson(), b.toJson()],
            }),
          );
          expect(notifications, 1);
        } finally {
          manager.removeListener(changed);
        }
      });
    },
  );

  test(
    'tracking folder switch does not relabel old cached identities',
    () async {
      final previous = appdata.settings['followUpdatesFolder'];
      try {
        await _withFavoritesManager((manager) async {
          for (final folder in ['track-a', 'track-b']) {
            manager.createFolder(folder);
            manager.prepareTableForFollowUpdates(folder);
          }
          final old = _favorite('old');
          final first = _favorite('first');
          final second = _favorite('second');
          manager.addComic('track-a', old);
          manager.addComic('track-b', first);
          manager.addComic('track-b', second);
          appdata.settings['followUpdatesFolder'] = 'track-a';
          manager.refreshUpdateIds();
          manager.updateUpdateTime('track-a', old.id, old.type, 'v1');
          manager.updateUpdateTime('track-b', first.id, first.type, 'v1');
          expect(manager.hasNewUpdate(old.id, old.type), isTrue);
          appdata.settings['followUpdatesFolder'] = 'track-b';
          expect(manager.hasNewUpdate(old.id, old.type), isFalse);
          manager.updateUpdateTime('track-b', second.id, second.type, 'v1');
          expect(manager.hasNewUpdate(old.id, old.type), isFalse);
          expect(manager.hasNewUpdate(first.id, first.type), isTrue);
          expect(manager.hasNewUpdate(second.id, second.type), isTrue);
          manager.markAsRead(first.id, first.type, notify: false);
          expect(manager.hasNewUpdate(first.id, first.type), isFalse);
          expect(manager.hasNewUpdate(second.id, second.type), isTrue);
        });
      } finally {
        appdata.settings['followUpdatesFolder'] = previous;
      }
    },
  );

  test(
    'failed clear restores original database and settings then permits retry',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('preserved');
        manager.addComic('preserved', _favorite('original'));
        appdata.settings['followUpdatesFolder'] = 'preserved';
        appdata.settings['quickFavorite'] = 'preserved';
        manager.prepareTableForFollowUpdates('preserved');
        manager.updateUpdateTime(
          'preserved',
          'original',
          ComicType.local,
          'v1',
        );
        await appdata.saveData(false);
        final blockedWrite = Directory('${App.dataPath}/appdata.json.tmp')
          ..createSync();
        try {
          await expectLater(
            manager.clearAll(),
            throwsA(isA<FileSystemException>()),
          );
          expect(manager.getFolderComics('preserved').single.id, 'original');
          expect(appdata.settings['followUpdatesFolder'], 'preserved');
          expect(appdata.settings['quickFavorite'], 'preserved');
          expect(manager.hasNewUpdate('original', ComicType.local), isTrue);
        } finally {
          blockedWrite.deleteSync();
        }
        await manager.clearAll();
        expect(manager.folderNames, [LocalFavoritesManager.trackingFolderName]);
        expect(manager.getAllComics(), isEmpty);
        expect(
          Directory(App.dataPath).listSync().where(
            (entry) => entry.path.contains('.favorite_clear_'),
          ),
          isEmpty,
        );
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'close drains all readers and rejects stale results before reopening',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('drain');
        manager.addComic('drain', _favorite('old'));
        await manager.debugWaitForHashedIdsRefresh();
        final reads = [
          manager.getFolderComicsAsync('drain'),
          manager.getAllComicsAsync(),
          manager.getFolderComicsAsync('drain'),
        ];
        final failures = reads
            .map((read) => expectLater(read, throwsStateError))
            .toList();
        manager.refreshHashedIds();
        manager.refreshHashedIds();
        final closing = manager.closeAndWait();
        expect(identical(closing, manager.closeAndWait()), isTrue);
        expect(manager.totalComics, 0);
        await closing;
        await Future.wait(failures);
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
    skip: !_sqliteAvailable(),
  );

  test('initialization waits for draining readers', () async {
    await _withFavoritesManager((manager) async {
      manager.createFolder('drain-reopen');
      await manager.debugWaitForHashedIdsRefresh();
      final read = manager.getAllComicsAsync();
      final failure = expectLater(read, throwsStateError);
      final closing = manager.closeAndWait();
      final reopened = manager.init();
      await closing;
      await failure;
      await reopened;
      expect(manager.folderNames, contains('drain-reopen'));
    });
  }, skip: !_sqliteAvailable());

  test(
    'clear shares one operation, drains readers and uses its owned path',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('clear-me');
        manager.addComic('clear-me', _favorite('old'));
        await manager.debugWaitForHashedIdsRefresh();
        final ownedPath = App.dataPath;
        final other = Directory.systemTemp.createTempSync(
          'favorites-clear-other-',
        );
        final otherFile = File('${other.path}/local_favorite.db')
          ..writeAsStringSync('untouched');
        try {
          final reading = manager.getAllComicsAsync();
          final readFailure = expectLater(reading, throwsStateError);
          App.dataPath = other.path;
          final clearing = manager.clearAll();
          expect(identical(clearing, manager.clearAll()), isTrue);
          await expectLater(manager.init(), throwsStateError);
          App.dataPath = ownedPath;
          expect(identical(clearing, manager.init()), isTrue);
          await clearing;
          await readFailure;
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
    skip: !_sqliteAvailable(),
  );

  test(
    'initialization reuses its future and close is repeatable',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('lifecycle');
        final item = _favorite('kept');
        manager.addComic('lifecycle', item);
        final ready = manager.init();
        expect(identical(ready, manager.init()), isTrue);
        await ready;
        expect(manager.isExist(item.id, item.type), isTrue);
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        manager.close();
        expect(manager.totalComics, 0);
        expect(manager.counts, isEmpty);
        expect(() => manager.folderNames, throwsStateError);
        final first = manager.init();
        final second = manager.init();
        expect(identical(first, second), isTrue);
        await first;
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.isExist(item.id, item.type), isTrue);
        expect(manager.counts['lifecycle'], 1);
        manager.close();
        final finishing = manager.init();
        final finishingRead = manager.debugWaitForHashedIdsRefresh();
        final closed = expectLater(finishing, throwsStateError);
        manager.close();
        await closed;
        await finishingRead;
        await manager.init();
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'failed migration releases connection and allows explicit retry',
    () async {
      await _withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        final path = '${App.dataPath}/local_favorite.db';
        final db = sqlite3.open(path);
        db.execute('DROP TABLE folder_order;');
        db.execute('CREATE TABLE folder_order (invalid TEXT);');
        db.dispose();
        final first = manager.init();
        final second = manager.init();
        expect(identical(first, second), isTrue);
        await expectLater(first, throwsA(isA<SqliteException>()));
        expect(() => manager.folderNames, throwsStateError);
        // Windows will reject renaming a file with an unreleased SQLite handle.
        File(path).renameSync('$path.failed');
        File('$path.failed').renameSync(path);
        final repaired = sqlite3.open(path);
        repaired.execute('DROP TABLE folder_order;');
        repaired.dispose();
        await manager.init();
        expect(
          manager.folderNames,
          contains(LocalFavoritesManager.trackingFolderName),
        );
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'closed initialization cannot dispose a reopened connection',
    () async {
      await _withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        appdata.settings['quickFavorite'] = 'missing-folder';
        final closing = manager.init();
        final failure = expectLater(closing, throwsStateError);
        manager.close();
        final reopened = manager.init();
        await failure;
        await reopened;
        manager.createFolder('reopened');
        expect(manager.folderNames, contains('reopened'));
        expect(identical(reopened, manager.init()), isTrue);
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'ready manager rejects implicit data path switching',
    () async {
      await _withFavoritesManager((manager) async {
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
    skip: !_sqliteAvailable(),
  );

  test(
    'colliding legacy hashes retain independent favorite and update state',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('identity-test');
        manager.createFolder('identity-copy');
        appdata.settings['followUpdatesFolder'] = 'identity-test';
        manager.prepareTableForFollowUpdates('identity-test');
        final first = _favorite('collision-first');
        final secondType = first.id.hashCode ^ 'collision-second'.hashCode;
        final second = FavoriteItem(
          id: 'collision-second',
          name: 'Second',
          coverPath: 'second.jpg',
          author: '',
          type: ComicType(secondType),
          tags: [],
        );
        expect(
          first.id.hashCode ^ first.type.value,
          second.id.hashCode ^ second.type.value,
        );
        manager.addComic('identity-test', first);
        manager.addComic('identity-test', second);
        manager.refreshHashedIds();
        // Commit both additions and removals while a snapshot is in flight.
        manager.addComic('identity-copy', first);
        manager.updateUpdateTime('identity-test', first.id, first.type, 'v1');
        expect(manager.hasNewUpdate(second.id, second.type), isFalse);
        manager.updateUpdateTime('identity-test', second.id, second.type, 'v2');
        manager.markAsRead(first.id, first.type);
        expect(manager.hasNewUpdate(second.id, second.type), isTrue);
        manager.deleteComicWithId('identity-test', first.id, first.type);
        expect(manager.isExist(first.id, first.type), isTrue);
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.totalComics, 2);
        manager.deleteFolder('identity-copy');
        expect(manager.isExist(first.id, first.type), isFalse);
        expect(manager.isExist(second.id, second.type), isTrue);
        expect(manager.totalComics, 1);
        expect(manager.hasNewUpdate(second.id, second.type), isTrue);
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'batch merge corrects reference counts before notification',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('merge-source');
        manager.createFolder('merge-target');
        final item = _favorite('merge-id');
        manager.addComic('merge-source', item);
        manager.addComic('merge-target', item);
        await manager.debugWaitForHashedIdsRefresh();
        manager.refreshHashedIds();
        manager.batchMoveFavorites('merge-source', 'merge-target', [item]);
        var notifications = 0;
        manager.addListener(() {
          notifications++;
          expect(manager.isExist(item.id, item.type), isFalse);
          expect(manager.totalComics, 0);
        });
        manager.deleteComicWithId('merge-target', item.id, item.type);
        expect(notifications, 1);
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.totalComics, 0);
      });
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'read failure preserves cache and notifications until commit',
    () async {
      final oldMovement = appdata.settings['moveFavoriteAfterRead'];
      final oldReadLater = appdata.settings['readLaterFolder'];
      try {
        await _withFavoritesManager((manager) async {
          manager.createFolder('tracking-read');
          manager.createFolder('read-copy');
          manager.createFolder('read-later');
          appdata.settings['followUpdatesFolder'] = 'tracking-read';
          appdata.settings['readLaterFolder'] = 'read-later';
          appdata.settings['moveFavoriteAfterRead'] = 'end';
          manager.prepareTableForFollowUpdates('tracking-read');
          final comic = _favorite('read-id');
          for (final folder in ['tracking-read', 'read-copy', 'read-later']) {
            manager.addComic(folder, comic, -1);
          }
          manager.updateUpdateTime('tracking-read', comic.id, comic.type, 'v1');
          await manager.debugWaitForHashedIdsRefresh();
          var notifications = 0;
          manager.addListener(() => notifications++);
          final db = sqlite3.open('${App.dataPath}/local_favorite.db');
          try {
            db.execute(
              """CREATE TRIGGER reject_read BEFORE UPDATE ON "read-copy" BEGIN SELECT RAISE(ABORT, 'blocked'); END;""",
            );
            expect(
              () => manager.onRead(comic.id, comic.type),
              throwsA(isA<SqliteException>()),
            );
            expect(manager.hasNewUpdate(comic.id, comic.type), isTrue);
            expect(notifications, 0);
            expect(
              db
                  .select('SELECT display_order FROM "tracking-read"')
                  .single['display_order'],
              -1,
            );
            db.execute('DROP TRIGGER reject_read;');
            manager.onRead(comic.id, comic.type);
            expect(manager.hasNewUpdate(comic.id, comic.type), isFalse);
            expect(notifications, 1);
            expect(
              db
                  .select('SELECT display_order FROM "read-copy"')
                  .single['display_order'],
              0,
            );
            expect(
              db
                  .select('SELECT display_order FROM "read-later"')
                  .single['display_order'],
              -1,
            );
          } finally {
            db.dispose();
          }
        });
      } finally {
        appdata.settings['moveFavoriteAfterRead'] = oldMovement;
        appdata.settings['readLaterFolder'] = oldReadLater;
      }
    },
    skip: !_sqliteAvailable(),
  );

  test(
    'folder notifications see counts and failed rename preserves settings',
    () async {
      await _withFavoritesManager((manager) async {
        const source = 'metadata-source';
        var notifications = 0;
        void listener() {
          notifications++;
          expect(manager.counts[source], 0);
          expect(manager.existsFolder(source), isTrue);
        }

        manager.addListener(listener);
        manager.createFolder(source);
        expect(notifications, 1);
        appdata.settings['quickFavorite'] = source;
        manager.linkFolderToNetwork(source, 'key', 'remote');
        final db = sqlite3.open('${App.dataPath}/local_favorite.db');
        try {
          db.execute(
            "CREATE TRIGGER reject_rename BEFORE UPDATE ON folder_sync BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
          );
          expect(
            () => manager.rename(source, 'new-name'),
            throwsA(isA<SqliteException>()),
          );
          expect(notifications, 1);
          expect(appdata.settings['quickFavorite'], source);
          expect(manager.counts[source], 0);
          expect(manager.existsFolder('new-name'), isFalse);
          expect(manager.findLinked(source), ('key', 'remote'));
        } finally {
          manager.removeListener(listener);
          db.dispose();
        }
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'deletion preserves shared covers and failed batches leave caches untouched',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('delete_one');
        manager.createFolder('delete_two');
        final item = _favorite('shared-cover');
        manager.addComic('delete_one', item);
        manager.addComic('delete_two', item);
        final directory = Directory('${App.dataPath}/favorite_cover')
          ..createSync();
        final cover = File(
          '${directory.path}/${(item.id + item.type.value.toString()).hashCode}',
        )..writeAsStringSync('cover');
        final db = sqlite3.open('${App.dataPath}/local_favorite.db');
        var notifications = 0;
        void listener() => notifications++;
        manager.addListener(listener);
        try {
          db.execute(
            "CREATE TRIGGER reject_delete BEFORE DELETE ON delete_two BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
          );
          expect(
            () => _deleteExternally(manager, [ComicID(item.type, item.id)]),
            throwsA(isA<SqliteException>()),
          );
          expect(notifications, 0);
          expect(manager.folderComics('delete_one'), 1);
          expect(manager.folderComics('delete_two'), 1);
          expect(manager.isExist(item.id, item.type), isTrue);
          expect(cover.readAsStringSync(), 'cover');
          db.execute('DROP TRIGGER reject_delete;');
          manager.batchDeleteComics('delete_one', [
            item,
            item,
            _favorite('missing'),
          ]);
          expect(notifications, 1);
          expect(manager.folderComics('delete_one'), 0);
          expect(manager.isExist(item.id, item.type), isTrue);
          expect(cover.existsSync(), isTrue);
          manager.deleteComicWithId('delete_one', item.id, item.type);
          expect(notifications, 1);
          expect(manager.folderComics('delete_one'), 0);
          manager.deleteComicWithId('delete_two', item.id, item.type);
          expect(notifications, 2);
          expect(manager.isExist(item.id, item.type), isFalse);
          expect(cover.existsSync(), isFalse);
        } finally {
          manager.removeListener(listener);
          db.dispose();
        }
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'failed and same-folder transfers do not notify or change cached counts',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('transfer_source');
        manager.createFolder('transfer_target');
        final items = [_favorite('a'), _favorite('b')];
        for (final item in items) {
          manager.addComic('transfer_source', item);
        }
        final db = sqlite3.open('${App.dataPath}/local_favorite.db');
        try {
          db.execute(
            "CREATE TRIGGER reject_transfer BEFORE INSERT ON transfer_target WHEN NEW.id = 'b' BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
          );
          var notifications = 0;
          void listener() => notifications++;
          manager.addListener(listener);
          try {
            manager.batchMoveFavorites(
              'transfer_source',
              'transfer_target',
              items,
            );
            manager.batchCopyFavorites(
              'transfer_source',
              'transfer_target',
              items,
            );
            manager.batchMoveFavorites(
              'transfer_source',
              'transfer_source',
              items,
            );
            manager.batchCopyFavorites(
              'transfer_source',
              'transfer_source',
              items,
            );
            expect(notifications, 0);
            expect(manager.folderComics('transfer_source'), 2);
            expect(manager.folderComics('transfer_target'), 0);
            expect(manager.count('transfer_source'), 2);
            expect(manager.count('transfer_target'), 0);
            db.execute('DROP TRIGGER reject_transfer;');
            manager.batchMoveFavorites(
              'transfer_source',
              'transfer_target',
              items,
            );
            expect(notifications, 1);
            expect(manager.folderComics('transfer_source'), 0);
            expect(manager.folderComics('transfer_target'), 2);
          } finally {
            manager.removeListener(listener);
          }
        } finally {
          db.dispose();
        }
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'isolate queries match synchronous folder order and aggregate identity',
    () async {
      await _withFavoritesManager((manager) async {
        manager.createFolder('one');
        manager.createFolder('two');
        manager.addComic('one', _favorite('later'), 10);
        manager.addComic('one', _favorite('first'), -5);
        manager.addComic('two', _favorite('first'), 0);
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
          await manager.findWithModel(_favorite('first')),
          manager.find('first', ComicType.local),
        );
        expect(
          () => manager.getComic('one', 'missing', ComicType.local),
          throwsException,
        );
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init creates tracking folder and selects it for follow updates',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;
      appdata.settings['followUpdatesFolder'] = 'obsolete-folder';
      appdata.settings['quickFavorite'] = 'obsolete-folder';

      final manager = LocalFavoritesManager();
      await manager.init();

      expect(
        manager.folderNames,
        contains(LocalFavoritesManager.trackingFolderName),
      );
      expect(
        appdata.settings['followUpdatesFolder'],
        LocalFavoritesManager.trackingFolderName,
      );
      expect(
        appdata.settings['quickFavorite'],
        LocalFavoritesManager.trackingFolderName,
      );

      final item = _favorite('tracked');
      manager.addComic(
        LocalFavoritesManager.trackingFolderName,
        item,
        null,
        '2026-07-02',
      );
      final tracked = manager.getComicsWithUpdatesInfo(
        LocalFavoritesManager.trackingFolderName,
      );

      expect(tracked, hasLength(1));
      expect(tracked.single.updateTime, '2026-07-02');
      expect(tracked.single.hasNewUpdate, isFalse);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init preserves valid quick favorite folder without creating tracking',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;
      appdata.settings['followUpdatesFolder'] = null;
      appdata.settings['quickFavorite'] = 'custom';

      final seed = sqlite3.open('${dataDir.path}/local_favorite.db');
      try {
        seed.execute("""
          create table folder_order (
            folder_name text primary key,
            order_value int
          );
        """);
        seed.execute("""
          create table folder_sync (
            folder_name text primary key,
            source_key text,
            source_folder text
          );
        """);
        seed.execute("""
          create table custom(
            id text,
            name TEXT,
            author TEXT,
            type int,
            tags TEXT,
            cover_path TEXT,
            time TEXT,
            display_order int,
            translated_tags TEXT,
            primary key (id, type)
          );
        """);
      } finally {
        seed.dispose();
      }

      final manager = LocalFavoritesManager();
      await manager.init();

      expect(appdata.settings['followUpdatesFolder'], isNull);
      expect(appdata.settings['quickFavorite'], 'custom');
      expect(
        manager.folderNames,
        isNot(contains(LocalFavoritesManager.trackingFolderName)),
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init preserves a custom tracking folder after restart',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        await appdata.saveData(false);
        if (LocalFavoritesManager.cache != null) {
          await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
          try {
            LocalFavoritesManager().close();
          } catch (_) {
            // ignore cleanup failures in partially initialized tests
          }
        }
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final firstManager = LocalFavoritesManager();
      await firstManager.init();
      firstManager.createFolder('B');
      appdata.settings['followUpdatesFolder'] = 'B';
      firstManager.prepareTableForFollowUpdates('B');
      firstManager.deleteFolder(LocalFavoritesManager.trackingFolderName);
      firstManager.close();
      LocalFavoritesManager.cache = null;

      final secondManager = LocalFavoritesManager();
      await secondManager.init();

      expect(secondManager.folderNames, ['B']);
      expect(appdata.settings['followUpdatesFolder'], 'B');
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'tracks cached update status for the follow updates folder',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      const folder = LocalFavoritesManager.trackingFolderName;
      final item = _favorite('updated-comic');

      manager.addComic(folder, item, null, '2026-07-01');
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);

      manager.updateUpdateTime(folder, item.id, item.type, '2026-07-02');
      expect(manager.hasNewUpdate(item.id, item.type), isTrue);

      manager.markAsRead(item.id, item.type, notify: false);
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'follow updates preview returns all comics in the tracking folder',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final updated = _favorite('updated-preview');
        final unchanged = _favorite('unchanged-preview');

        manager.addComic(folder, updated, null, '2026-07-01');
        manager.addComic(folder, unchanged, null, '2026-07-01');
        manager.updateUpdateTime(
          folder,
          updated.id,
          updated.type,
          '2026-07-02',
        );

        final preview = getFollowUpdatesPreviewComics(folder);

        expect(
          preview.map((comic) => comic.id),
          unorderedEquals([updated.id, unchanged.id]),
        );
        expect(preview.where((comic) => comic.hasNewUpdate), hasLength(1));
        expect(manager.countUpdates(folder), 1);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'delete and move operations clear cached follow update status',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        manager.createFolder('target');

        void addUpdated(FavoriteItem item) {
          manager.addComic(folder, item, null, '2026-07-01');
          manager.updateUpdateTime(folder, item.id, item.type, '2026-07-02');
          expect(manager.hasNewUpdate(item.id, item.type), isTrue);
        }

        final deleted = _favorite('delete-one');
        addUpdated(deleted);
        manager.deleteComicWithId(folder, deleted.id, deleted.type);
        expect(manager.hasNewUpdate(deleted.id, deleted.type), isFalse);

        final batchDeleted = _favorite('delete-batch');
        addUpdated(batchDeleted);
        manager.batchDeleteComics(folder, [batchDeleted]);
        expect(
          manager.hasNewUpdate(batchDeleted.id, batchDeleted.type),
          isFalse,
        );

        final deletedEverywhere = _favorite('delete-everywhere');
        addUpdated(deletedEverywhere);
        _deleteExternally(manager, [
          ComicID(deletedEverywhere.type, deletedEverywhere.id),
        ]);
        expect(
          manager.hasNewUpdate(deletedEverywhere.id, deletedEverywhere.type),
          isFalse,
        );

        final moved = _favorite('move-one');
        addUpdated(moved);
        manager.moveFavorite(folder, 'target', moved.id, moved.type);
        expect(manager.hasNewUpdate(moved.id, moved.type), isFalse);

        final batchMoved = _favorite('move-batch');
        addUpdated(batchMoved);
        manager.batchMoveFavorites(folder, 'target', [batchMoved]);
        expect(manager.hasNewUpdate(batchMoved.id, batchMoved.type), isFalse);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'folder delete and rename refresh cached follow update status',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final renamed = _favorite('rename-follow');

        manager.addComic(folder, renamed, null, '2026-07-01');
        manager.updateUpdateTime(
          folder,
          renamed.id,
          renamed.type,
          '2026-07-02',
        );
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        manager.rename(folder, 'renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], 'renamed-follow');
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        manager.deleteFolder('renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], isNull);
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isFalse);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'empty batch favorite operations do not notify listeners',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('source');
      manager.createFolder('target');

      var notifyCount = 0;
      void listener() {
        notifyCount++;
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));

      manager.batchMoveFavorites('source', 'target', <FavoriteItem>[]);
      manager.batchCopyFavorites('source', 'target', <FavoriteItem>[]);
      manager.batchDeleteComics('source', <FavoriteItem>[]);
      _deleteExternally(manager, []);

      expect(notifyCount, 0);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 0);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'batchMoveFavorites notifies after counts are updated',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('source');
      manager.createFolder('target');
      final first = _favorite('first');
      final second = _favorite('second');
      manager.addComic('source', first);
      manager.addComic('source', second);

      final observedCounts = <(int source, int target)>[];
      var isBatching = false;
      void listener() {
        if (isBatching) {
          observedCounts.add((
            manager.folderComics('source'),
            manager.folderComics('target'),
          ));
        }
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));

      isBatching = true;
      manager.batchMoveFavorites('source', 'target', [first, second]);
      isBatching = false;

      expect(observedCounts, [(0, 2)]);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 2);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
