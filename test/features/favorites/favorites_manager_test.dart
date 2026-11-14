import 'dart:convert';
import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'support/favorites_manager_fixture.dart';
import '../../support/sqlite_test_environment.dart';

void main() {
  test(
    'case-only folder rename preserves settings and rejects other names',
    () async {
      await withFavoritesManager((manager) async {
        final previousLater = appdata.settings['readLaterFolder'];
        try {
          await manager.createFolder('ip');
          await manager.createFolder('IP0');
          await manager.addComic('ip', managerFavorite('kept'));
          await manager.prepareTableForFollowUpdates('ip');
          final id = manager.folderTree.named('ip')!.id;
          for (final key in [
            'readLaterFolder',
            'quickFavorite',
            'followUpdatesFolder',
          ]) {
            appdata.settings[key] = 'ip';
          }
          await expectLater(manager.createFolder('IP'), throwsException);
          expect(await manager.createFolder('IP', true), 'IP1');
          await expectLater(manager.rename('ip', 'ip0'), throwsException);
          await manager.rename('ip', 'IP');
          expect(manager.folderTree.named('IP')!.id, id);
          expect(manager.folderComics('IP'), 1);
          expect(manager.getFolderComics('IP').single.id, 'kept');
          for (final key in [
            'readLaterFolder',
            'quickFavorite',
            'followUpdatesFolder',
          ]) {
            expect(appdata.settings[key], 'IP');
          }
          await manager.rename('IP', 'IP');
          await manager.closeAndWait();
          await manager.init();
          expect(manager.folderTree.named('IP')!.id, id);
          expect(manager.getFolderComics('IP').single.id, 'kept');
        } finally {
          appdata.settings['readLaterFolder'] = previousLater;
        }
      });
    },
  );

  for (final action in [
    'add',
    'storage add',
    'move',
    'batch move',
    'batch copy',
    'delete',
    'batch delete',
    'external delete',
    'read',
    'mark read',
    'read later add',
    'read later remove',
  ]) {
    test(
      'R2 $action publishes committed state after tracking failure',
      () async {
        await withFavoritesManager((manager) async {
          final previousLater = appdata.settings['readLaterFolder'];
          final previousMovement = appdata.settings['moveFavoriteAfterRead'];
          await manager.createFolder('source');
          await manager.createFolder('target');
          await manager.prepareTableForFollowUpdates('target');
          await manager.addComic('source', managerFavorite('moving'));
          await manager.addComic('target', managerFavorite('existing'));
          appdata.settings['followUpdatesFolder'] = 'target';
          appdata.settings['moveFavoriteAfterRead'] = 'end';
          if (action.startsWith('read later')) {
            appdata.settings['readLaterFolder'] = 'target';
          }
          await manager.updateUpdateTime(
            'target',
            'existing',
            ComicType.local,
            'new chapter',
          );
          final expected = switch (action) {
            'add' || 'storage add' || 'read later add' => ['existing', 'new'],
            'move' || 'batch move' || 'batch copy' => ['existing', 'moving'],
            'delete' ||
            'batch delete' ||
            'external delete' ||
            'read later remove' => <String>[],
            _ => ['existing'],
          };
          final published = <List<String>>[];
          void changed() => published.add(
            manager.getFolderComics('target').map((comic) => comic.id).toList(),
          );
          final failure = StateError('R2 tracking observer');
          manager.addListener(changed);
          registerFollowUpdatesChangeListener(() => throw failure);
          try {
            Object? observed;
            try {
              switch (action) {
                case 'add':
                  await manager.addComic('target', managerFavorite('new'));
                case 'storage add':
                  await manager.addComicWithStorage('target', ['tag'], (
                    path,
                    translated,
                    append,
                  ) {
                    final db = sqlite3.open(path);
                    try {
                      final item = managerFavorite('new');
                      FavoritesRepository(db).addComic(
                        'target',
                        item,
                        translatedTags: translated,
                        append: append,
                      );
                      return item;
                    } finally {
                      db.dispose();
                    }
                  });
                case 'move':
                  await manager.moveFavorite(
                    'source',
                    'target',
                    'moving',
                    ComicType.local,
                  );
                case 'batch move':
                  await manager.batchMoveFavorites('source', 'target', [
                    managerFavorite('moving'),
                  ]);
                case 'batch copy':
                  await manager.batchCopyFavorites('source', 'target', [
                    managerFavorite('moving'),
                  ]);
                case 'delete':
                  await manager.deleteComicWithId(
                    'target',
                    'existing',
                    ComicType.local,
                  );
                case 'batch delete':
                  await manager.batchDeleteComics('target', [
                    managerFavorite('existing'),
                  ]);
                case 'external delete':
                  deleteFavoritesExternally(manager, [
                    ComicID(ComicType.local, 'existing'),
                  ]);
                case 'read':
                  await manager.onRead('existing', ComicType.local);
                case 'mark read':
                  await manager.markAsRead('existing', ComicType.local);
                case 'read later add':
                  await manager.setReadLater(
                    managerFavorite('new'),
                    included: true,
                    folderName: 'unused',
                  );
                case 'read later remove':
                  await manager.setReadLater(
                    managerFavorite('existing'),
                    included: false,
                    folderName: 'unused',
                  );
              }
            } catch (error) {
              observed = error;
            }
            expect(published, hasLength(1));
            expect(published.single, unorderedEquals(expected));
            expect(
              observed,
              isA<PersistenceFailure>()
                  .having(
                    (value) => value.commitState,
                    'commit',
                    PersistenceCommitState.committed,
                  )
                  .having((value) => value.cause, 'cause', same(failure)),
            );
            expect(manager.folderComics('target'), expected.length);
            registerFollowUpdatesChangeListener(null);
            manager.removeListener(changed);
            await manager.closeAndWait();
            await manager.init();
            expect(
              manager.getFolderComics('target').map((comic) => comic.id),
              unorderedEquals(expected),
            );
            if (action == 'read' || action == 'mark read') {
              expect(
                manager.hasNewUpdate('existing', ComicType.local),
                isFalse,
              );
            }
          } finally {
            registerFollowUpdatesChangeListener(null);
            manager.removeListener(changed);
            appdata.settings['readLaterFolder'] = previousLater;
            appdata.settings['moveFavoriteAfterRead'] = previousMovement;
          }
        });
      },
    );
  }

  test(
    'R1 bulk favorites roll back together and retry without duplicate identities',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('bulk');
        final db = sqlite3.open(manager.databasePath);
        try {
          db.execute(
            "CREATE TRIGGER fail_bulk BEFORE INSERT ON bulk WHEN new.id = 'bad' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
          );
          final items = [
            managerFavorite('good'),
            managerFavorite('bad'),
            managerFavorite('good'),
          ];
          await expectLater(
            manager.addComics('bulk', items),
            throwsA(
              isA<PersistenceFailure>().having(
                (failure) => failure.commitState,
                'commit',
                PersistenceCommitState.notCommitted,
              ),
            ),
          );
          expect(manager.getFolderComics('bulk'), isEmpty);
          expect(manager.folderComics('bulk'), 0);
          db.execute('DROP TRIGGER fail_bulk');
          expect(await manager.addComics('bulk', items), 2);
          expect(await manager.addComics('bulk', items), 0);
          expect(
            manager.getFolderComics('bulk').map((item) => item.id),
            unorderedEquals(['good', 'bad']),
          );
          await manager.closeAndWait();
          await manager.init();
          expect(
            manager.getFolderComics('bulk').map((item) => item.id),
            unorderedEquals(['good', 'bad']),
          );
        } finally {
          db.dispose();
        }
      });
    },
  );

  test('R1 queued bulk favorites snapshot values and notify once', () async {
    await withFavoritesManager((manager) async {
      await manager.createFolder('bulk');
      final release = Completer<void>();
      final lock = AppDataOperations.instance.run(() => release.future);
      final first = managerFavorite('original')..tags = ['original-tag'];
      final items = [first, managerFavorite('other')];
      var notifications = 0;
      void changed() => notifications++;
      manager.addListener(changed);
      final saving = manager.addComics('bulk', items);
      first.id = 'replacement';
      first.tags.add('late');
      items.clear();
      release.complete();
      await lock;
      expect(await saving, 2);
      expect(manager.getComic('bulk', 'original', ComicType.local).tags, [
        'original-tag',
      ]);
      expect(notifications, 1);
      manager.removeListener(changed);
    });
  });

  for (final transfer in [false, true]) {
    test(
      'R1 committed ${transfer ? 'transfer' : 'bulk add'} refreshes views after observer failure',
      () async {
        await withFavoritesManager((manager) async {
          await manager.createFolder('source');
          await manager.createFolder('target');
          await manager.prepareTableForFollowUpdates('target');
          await manager.addComic('source', managerFavorite('new'));
          appdata.settings['followUpdatesFolder'] = 'target';
          var notifications = 0;
          void changed() => notifications++;
          manager.addListener(changed);
          final failure = StateError('tracking observer');
          registerFollowUpdatesChangeListener(() => throw failure);
          try {
            final work = transfer
                ? manager.transferFavorites(
                    'source',
                    ['target'],
                    [managerFavorite('new')],
                    move: true,
                  )
                : manager.addComics('target', [managerFavorite('new')]);
            await expectLater(
              work,
              throwsA(
                isA<PersistenceFailure>()
                    .having(
                      (value) => value.commitState,
                      'commit',
                      PersistenceCommitState.committed,
                    )
                    .having((value) => value.cause, 'cause', same(failure)),
              ),
            );
            expect(manager.getFolderComics('target').single.id, 'new');
            expect(manager.folderComics('target'), 1);
            expect(notifications, 1);
          } finally {
            registerFollowUpdatesChangeListener(null);
            manager.removeListener(changed);
          }
        });
      },
    );
  }

  test(
    'queued favorite writes capture their mutable inputs before admission',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('queued');
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final item = managerFavorite('original')..tags = ['original-tag'];
        final adding = manager.addComic('queued', item);
        item.id = 'changed';
        item.tags.add('late-tag');
        expect(manager.count('queued'), 0);
        release.complete();
        await Future.wait([exclusive, adding]);
        final stored = manager.getFolderComics('queued').single;
        expect(stored.id, 'original');
        expect(stored.tags, ['original-tag']);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'multi-folder transfer commits all destinations and source in one transaction',
    () async {
      await withFavoritesManager((manager) async {
        for (final name in ['source', 'first', 'second']) {
          await manager.createFolder(name);
        }
        final item = managerFavorite('transfer');
        await manager.addComic('source', item);
        final db = sqlite3.open(manager.databasePath);
        var notifications = 0;
        void changed() => notifications++;
        manager.addListener(changed);
        try {
          db.execute(
            "CREATE TRIGGER reject_second BEFORE INSERT ON second BEGIN SELECT RAISE(ABORT, 'second failed'); END;",
          );
          await expectLater(
            manager.transferFavorites(
              'source',
              ['first', 'second'],
              [item],
              move: true,
            ),
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (error) => error.commitState,
                    'commit state',
                    PersistenceCommitState.notCommitted,
                  )
                  .having(
                    (error) => error.cause,
                    'original SQL failure',
                    isA<SqliteException>(),
                  ),
            ),
          );
          expect(
            [
              manager.count('source'),
              manager.count('first'),
              manager.count('second'),
            ],
            [1, 0, 0],
          );
          expect(
            [
              manager.folderComics('source'),
              manager.folderComics('first'),
              manager.folderComics('second'),
            ],
            [1, 0, 0],
          );
          expect(notifications, 0);
          db.execute('DROP TRIGGER reject_second');
          await manager.transferFavorites(
            'source',
            ['first', 'second'],
            [item],
            move: true,
          );
          expect(
            [
              manager.count('source'),
              manager.count('first'),
              manager.count('second'),
            ],
            [0, 1, 1],
          );
          expect(manager.totalComics, 1);
          expect(notifications, 1);
        } finally {
          manager.removeListener(changed);
          db.dispose();
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'follow metadata and time roll back together and preserve existing unread state',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final item = managerFavorite('follow');
        await manager.addComic(folder, item, null, 'old');
        final updated = item.detached()..name = 'Updated title';
        final db = sqlite3.open(manager.databasePath);
        try {
          db.execute(
            'CREATE TRIGGER reject_follow BEFORE UPDATE OF last_update_time ON "$folder" BEGIN SELECT RAISE(ABORT, \'time failed\'); END;',
          );
          await expectLater(
            manager.applyFollowUpdate(
              folder,
              updated,
              'new',
              generation: manager.connectionGeneration,
              checkActive: () {},
            ),
            throwsA(isA<SqliteException>()),
          );
          expect(manager.getFolderComics(folder).single.name, item.name);
          expect(
            manager.getComicsWithUpdatesInfo(folder).single.updateTime,
            'old',
          );
          expect(manager.hasNewUpdate(item.id, item.type), isFalse);
          db.execute('DROP TRIGGER reject_follow');
          expect(
            await manager.applyFollowUpdate(
              folder,
              updated,
              'new',
              generation: manager.connectionGeneration,
              checkActive: () {},
            ),
            isTrue,
          );
          expect(
            await manager.applyFollowUpdate(
              folder,
              updated,
              'new',
              generation: manager.connectionGeneration,
              checkActive: () {},
            ),
            isFalse,
          );
          expect(manager.hasNewUpdate(item.id, item.type), isTrue);
          expect(
            manager.getComicsWithUpdatesInfo(folder).single.hasNewUpdate,
            isTrue,
          );
        } finally {
          db.dispose();
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'folder observer failure retains committed rename and publishes ordinary views',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final item = managerFavorite('rename');
        await manager.addComic(folder, item);
        var notifications = 0;
        void changed() => notifications++;
        manager.addListener(changed);
        registerFollowUpdatesChangeListener(() => throw StateError('observer'));
        try {
          await expectLater(
            manager.rename(folder, 'renamed'),
            throwsA(
              isA<PersistenceFailure>().having(
                (failure) => failure.commitState,
                'commit state',
                PersistenceCommitState.committed,
              ),
            ),
          );
          expect(manager.existsFolder(folder), isFalse);
          expect(manager.isExist(item.id, item.type), isTrue);
          expect(appdata.settings['followUpdatesFolder'], 'renamed');
          expect(notifications, 1);
        } finally {
          registerFollowUpdatesChangeListener(null);
          manager.removeListener(changed);
        }
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'network publication failure preserves commit and still notifies views',
    () async {
      await withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        final result = await manager.importNetworkFavorites(
          'Network',
          'test',
          'remote',
          [managerFavorite('network-one')],
          oldToNew: false,
        );
        expect(result.count, 1);
        await manager.prepareTableForFollowUpdates('Network');
        appdata.settings['followUpdatesFolder'] = 'Network';
        var notifications = 0;
        void changed() {
          notifications++;
        }

        manager.addListener(changed);
        registerFollowUpdatesChangeListener(() => throw StateError('observer'));
        try {
          await expectLater(
            manager.publishNetworkFavoriteImport(result),
            throwsA(
              isA<PersistenceFailure>().having(
                (failure) => failure.commitState,
                'commit',
                PersistenceCommitState.committed,
              ),
            ),
          );
          expect(manager.folderComics('Network'), 1);
          expect(manager.isExist('network-one', ComicType.local), isTrue);
          expect(notifications, 1);
          registerFollowUpdatesChangeListener(null);
          await manager.publishNetworkFavoriteImport(result);
          expect(notifications, 2);
          expect(manager.count('Network'), 1);
        } finally {
          registerFollowUpdatesChangeListener(null);
          manager.removeListener(changed);
        }
      });
    },
  );

  test(
    'folder JSON import publishes complete counts once and malformed input not at all',
    () async {
      await withFavoritesManager((manager) async {
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
          final a = managerFavorite('json-a')..type = const ComicType(17);
          final b = managerFavorite('json-b')..type = const ComicType(17);
          expect(
            () async => await manager.fromJson(
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
          await manager.fromJson(
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
    'failed clear restores original database and settings then permits retry',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('preserved');
        await manager.addComic('preserved', managerFavorite('original'));
        appdata.settings['followUpdatesFolder'] = 'preserved';
        appdata.settings['quickFavorite'] = 'preserved';
        await manager.prepareTableForFollowUpdates('preserved');
        await manager.updateUpdateTime(
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
            throwsA(
              isA<PersistenceFailure>()
                  .having(
                    (e) => e.commitState,
                    'state',
                    PersistenceCommitState.unknown,
                  )
                  .having(
                    (e) => e.cause,
                    'original write',
                    isA<FileSystemException>(),
                  )
                  .having(
                    (e) => e.cleanupFailures.single.error,
                    'recovery write',
                    isA<FileSystemException>(),
                  ),
            ),
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
    skip: !sqliteTestAvailable(),
  );

  test(
    'batch merge corrects reference counts before notification',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('merge-source');
        await manager.createFolder('merge-target');
        final item = managerFavorite('merge-id');
        await manager.addComic('merge-source', item);
        await manager.addComic('merge-target', item);
        await manager.debugWaitForHashedIdsRefresh();
        manager.refreshHashedIds();
        await manager.batchMoveFavorites('merge-source', 'merge-target', [
          item,
        ]);
        var notifications = 0;
        manager.addListener(() {
          notifications++;
          expect(manager.isExist(item.id, item.type), isFalse);
          expect(manager.totalComics, 0);
        });
        await manager.deleteComicWithId('merge-target', item.id, item.type);
        expect(notifications, 1);
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.totalComics, 0);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'read failure preserves cache and notifications until commit',
    () async {
      final oldMovement = appdata.settings['moveFavoriteAfterRead'];
      final oldReadLater = appdata.settings['readLaterFolder'];
      try {
        await withFavoritesManager((manager) async {
          await manager.createFolder('tracking-read');
          await manager.createFolder('read-copy');
          await manager.createFolder('read-later');
          appdata.settings['followUpdatesFolder'] = 'tracking-read';
          appdata.settings['readLaterFolder'] = 'read-later';
          appdata.settings['moveFavoriteAfterRead'] = 'end';
          await manager.prepareTableForFollowUpdates('tracking-read');
          final comic = managerFavorite('read-id');
          for (final folder in ['tracking-read', 'read-copy', 'read-later']) {
            await manager.addComic(folder, comic, -1);
          }
          await manager.updateUpdateTime(
            'tracking-read',
            comic.id,
            comic.type,
            'v1',
          );
          await manager.debugWaitForHashedIdsRefresh();
          var notifications = 0;
          manager.addListener(() => notifications++);
          final db = sqlite3.open('${App.dataPath}/local_favorite.db');
          try {
            db.execute(
              """CREATE TRIGGER reject_read BEFORE UPDATE ON "read-copy" BEGIN SELECT RAISE(ABORT, 'blocked'); END;""",
            );
            expect(
              () async => await manager.onRead(comic.id, comic.type),
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
            await manager.onRead(comic.id, comic.type);
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
    skip: !sqliteTestAvailable(),
  );

  test(
    'folder notifications see counts and failed rename preserves settings',
    () async {
      await withFavoritesManager((manager) async {
        const source = 'metadata-source';
        var notifications = 0;
        void listener() {
          notifications++;
          expect(manager.counts[source], 0);
          expect(manager.existsFolder(source), isTrue);
        }

        manager.addListener(listener);
        await manager.createFolder(source);
        expect(notifications, 1);
        appdata.settings['quickFavorite'] = source;
        await manager.linkFolderToNetwork(source, 'key', 'remote');
        final db = sqlite3.open('${App.dataPath}/local_favorite.db');
        try {
          db.execute(
            "CREATE TRIGGER reject_rename BEFORE UPDATE ON folder_sync BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
          );
          expect(
            () async => await manager.rename(source, 'new-name'),
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
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'deletion preserves shared covers and failed batches leave caches untouched',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('delete_one');
        await manager.createFolder('delete_two');
        final item = managerFavorite('shared-cover');
        await manager.addComic('delete_one', item);
        await manager.addComic('delete_two', item);
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
            () => deleteFavoritesExternally(manager, [
              ComicID(item.type, item.id),
            ]),
            throwsA(isA<SqliteException>()),
          );
          expect(notifications, 0);
          expect(manager.folderComics('delete_one'), 1);
          expect(manager.folderComics('delete_two'), 1);
          expect(manager.isExist(item.id, item.type), isTrue);
          expect(cover.readAsStringSync(), 'cover');
          db.execute('DROP TRIGGER reject_delete;');
          await manager.batchDeleteComics('delete_one', [
            item,
            item,
            managerFavorite('missing'),
          ]);
          expect(notifications, 1);
          expect(manager.folderComics('delete_one'), 0);
          expect(manager.isExist(item.id, item.type), isTrue);
          expect(cover.existsSync(), isTrue);
          await manager.deleteComicWithId('delete_one', item.id, item.type);
          expect(notifications, 1);
          expect(manager.folderComics('delete_one'), 0);
          await manager.deleteComicWithId('delete_two', item.id, item.type);
          expect(notifications, 2);
          expect(manager.isExist(item.id, item.type), isFalse);
          expect(cover.existsSync(), isFalse);
        } finally {
          manager.removeListener(listener);
          db.dispose();
        }
      });
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'failed and same-folder transfers do not notify or change cached counts',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('transfer_source');
        await manager.createFolder('transfer_target');
        final items = [managerFavorite('a'), managerFavorite('b')];
        for (final item in items) {
          await manager.addComic('transfer_source', item);
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
            await expectLater(
              manager.batchMoveFavorites(
                'transfer_source',
                'transfer_target',
                items,
              ),
              throwsA(isA<SqliteException>()),
            );
            await expectLater(
              manager.batchCopyFavorites(
                'transfer_source',
                'transfer_target',
                items,
              ),
              throwsA(isA<SqliteException>()),
            );
            await manager.batchMoveFavorites(
              'transfer_source',
              'transfer_source',
              items,
            );
            await manager.batchCopyFavorites(
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
            await manager.batchMoveFavorites(
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
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
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
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      final manager = ownedFavoritesManager();
      await manager.init();
      await manager.createFolder('source');
      await manager.createFolder('target');

      var notifyCount = 0;
      void listener() {
        notifyCount++;
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));

      await manager.batchMoveFavorites('source', 'target', <FavoriteItem>[]);
      await manager.batchCopyFavorites('source', 'target', <FavoriteItem>[]);
      await manager.batchDeleteComics('source', <FavoriteItem>[]);
      deleteFavoritesExternally(manager, []);

      expect(notifyCount, 0);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 0);
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
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
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      final manager = ownedFavoritesManager();
      await manager.init();
      await manager.createFolder('source');
      await manager.createFolder('target');
      final first = managerFavorite('first');
      final second = managerFavorite('second');
      await manager.addComic('source', first);
      await manager.addComic('source', second);

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
      await manager.batchMoveFavorites('source', 'target', [first, second]);
      isBatching = false;

      expect(observedCounts, [(0, 2)]);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 2);
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );
}
