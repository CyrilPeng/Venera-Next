import 'package:venera_next/features/history/history_repository.dart';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';

History _history(String id) {
  return History.fromMap({
    'type': ComicType.local.value,
    'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
    'title': 'Title $id',
    'subtitle': 'Author',
    'cover': 'cover.jpg',
    'ep': 1,
    'page': 2,
    'id': id,
    'readEpisode': ['1'],
    'max_page': 10,
  });
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

void main() {
  group(
    'ordered history mutations',
    () {
      late Directory directory;
      late HistoryManager manager;
      setUp(() async {
        directory = Directory.systemTemp.createTempSync('history-order-');
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        manager = HistoryManager();
        await manager.init();
      });
      tearDown(() async {
        await manager.waitForAsyncWrites();
        manager.close();
        HistoryManager.cache = null;
        directory.deleteSync(recursive: true);
      });

      test(
        'external imports preserve queue order, failure recovery and connection ownership',
        () async {
          final original = _history('queued-import');
          final first = manager.addHistory(original);
          var committed = false;
          final importing = manager.importStorage(
            (path) {
              final db = sqlite3.open(path);
              try {
                final repository = HistoryRepository(db);
                expect(
                  repository.find(original.id, original.type.value)!.page,
                  2,
                );
                repository.importHistory(
                  original.copy()
                    ..page = 7
                    ..title = 'Imported',
                );
              } finally {
                db.dispose();
              }
            },
            onCommitted: () {
              committed = true;
              expect(manager.find(original.id, original.type)!.page, 7);
            },
          );
          final later = manager.addHistory(original.copy()..page = 9);
          await Future.wait([first, importing, later]);
          expect(committed, isTrue);
          expect(manager.find(original.id, original.type)!.page, 9);
          expect(manager.find(original.id, original.type)!.title, 'Imported');
          var failedNotification = false;
          await expectLater(
            manager.importStorage(
              (_) => throw StateError('injected'),
              onCommitted: () => failedNotification = true,
            ),
            throwsStateError,
          );
          expect(failedNotification, isFalse);
          await manager.addHistory(original.copy()..page = 10);
          expect(manager.find(original.id, original.type)!.page, 10);
          var staleWrite = false;
          final stale = manager.importStorage(
            (_) => staleWrite = true,
            onCommitted: () {},
          );
          manager.close();
          await expectLater(stale, throwsStateError);
          expect(staleWrite, isFalse);
          await manager.init();
        },
      );

      test(
        'external commit notification refreshes values before listeners run',
        () async {
          final original = _history('external');
          await manager.addHistory(original);
          expect(manager.find(original.id, original.type)!.page, 2);
          final repository = HistoryRepository(manager.imageFavoritesDatabase);
          final updated = original.copy()
            ..title = 'Imported title'
            ..page = 9;
          repository.importHistory(updated);
          var notifications = 0;
          void changed() {
            notifications++;
            expect(
              manager.find(original.id, original.type)!.title,
              'Imported title',
            );
            expect(manager.find(original.id, original.type)!.page, 9);
          }

          manager.addListener(changed);
          try {
            manager.notifyChanges();
            expect(notifications, 1);
          } finally {
            manager.removeListener(changed);
          }
          final later = updated.copy()..page = 10;
          await manager.addHistory(later);
          expect(manager.find(original.id, original.type)!.page, 10);
          expect(
            manager.find(original.id, original.type)!.title,
            'Imported title',
          );
        },
      );

      test(
        'source refresh preserves newer progress and later saves preserve metadata',
        () async {
          const key = 'history_metadata_test';
          final response = Completer<Res<ComicDetails>>();
          final requested = <String>[];
          ComicSourceManager().add(
            _source(
              key,
              loadComicInfo: (id) {
                requested.add(id);
                return response.future;
              },
            ),
          );
          addTearDown(() => ComicSourceManager().remove(key));
          final stale = _history('original')..type = ComicType.fromKey(key);
          await manager.addHistory(stale);
          final refreshing = manager.refreshHistoryInfo(stale);
          final progress = stale.copy()
            ..page = 9
            ..ep = 4
            ..group = 2
            ..maxPage = 80
            ..time = DateTime(2026, 10, 2)
            ..readEpisode.add('2-4');
          await manager.addHistory(progress);
          await manager.addReadDuration(
            progress,
            const Duration(milliseconds: 80),
          );
          stale.id = 'mutated';
          response.complete(
            Res(
              ComicDetails.fromJson({
                'title': 'Refreshed',
                'subtitle': 'New author',
                'cover': 'new-cover',
                'tags': <String, dynamic>{},
                'sourceKey': key,
                'comicId': 'original',
              }),
            ),
          );
          expect(await refreshing, isTrue);
          expect(requested, ['original']);
          var stored = manager.find('original', progress.type)!;
          expect(stored.title, 'Refreshed');
          expect(stored.subtitle, 'New author');
          expect(stored.cover, 'new-cover');
          expect(stored.page, 9);
          expect(stored.ep, 4);
          expect(stored.group, 2);
          expect(stored.maxPage, 80);
          expect(stored.time, progress.time);
          expect(stored.readEpisode, {'1', '2-4'});
          expect(stored.readDurationMs, 80);
          progress.page = 10;
          await manager.addHistory(progress);
          stored = manager.find('original', progress.type)!;
          expect(stored.page, 10);
          expect(stored.title, 'Refreshed');
          expect(stored.cover, 'new-cover');
        },
      );

      test(
        'metadata refresh does not recreate deletion or follow database reopen',
        () async {
          final item = _history('deleted');
          await manager.addHistory(item);
          final update = manager.metadataUpdaterFor(item);
          final deletion = manager.remove(item.id, item.type);
          expect(await update(title: 'Late title'), isFalse);
          await deletion;
          expect(manager.count(), 0);
          manager.close();
          final reopened = Directory('${directory.path}/new')..createSync();
          App.dataPath = reopened.path;
          await manager.init();
          await manager.addHistory(item);
          expect(await update(cover: 'Old lifetime'), isFalse);
          expect(manager.find(item.id, item.type)!.cover, 'cover.jpg');
        },
      );

      test(
        'import explicitly replaces metadata and progress while retaining duration',
        () async {
          final item = _history('import');
          await manager.addHistory(item);
          await manager.addReadDuration(item, const Duration(milliseconds: 50));
          final imported = item.copy()
            ..page = 7
            ..title = 'Imported'
            ..cover = 'import-cover';
          await manager.importHistory(imported);
          final stored = manager.find(item.id, item.type)!;
          expect(stored.title, 'Imported');
          expect(stored.cover, 'import-cover');
          expect(stored.page, 7);
          expect(stored.readDurationMs, 50);
        },
      );

      test(
        'latest progress and deletes follow earlier accepted writes',
        () async {
          final first = _history('same')..page = 3;
          final last = first.copy()..page = 8;
          final writes = [
            manager.addHistory(first),
            manager.addReadDuration(first, const Duration(milliseconds: 42)),
            manager.addHistory(last),
          ];
          expect(manager.hasPendingWrites, isTrue);
          await Future.wait(writes);
          expect(manager.find('same', ComicType.local)!.page, 8);
          expect(manager.find('same', ComicType.local)!.readDurationMs, 42);
          final rewriting = manager.addHistory(first);
          final deleting = manager.remove('same', ComicType.local);
          await Future.wait([rewriting, deleting]);
          expect(manager.find('same', ComicType.local), isNull);
          final batchWrite = manager.addHistory(_history('batch'));
          final ids = [ComicID(ComicType.local, 'batch')];
          final batchDelete = manager.batchDeleteHistories(ids);
          ids.clear();
          await Future.wait([batchWrite, batchDelete]);
          expect(manager.count(), 0);
          expect(manager.hasPendingWrites, isFalse);
        },
      );

      test('failed writes do not poison later queued mutations', () async {
        final db = sqlite3.open('${directory.path}/history.db');
        try {
          db.execute("""
          CREATE TRIGGER reject_bad BEFORE INSERT ON history
          WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'rejected'); END;
        """);
          final failure = expectLater(
            manager.addHistory(_history('bad')),
            throwsA(isA<SqliteException>()),
          );
          final following = manager.addHistory(_history('good'));
          await failure;
          await following;
          await manager.waitForAsyncWrites();
          expect(manager.getAll().map((item) => item.id), ['good']);
          expect(manager.hasPendingWrites, isFalse);
        } finally {
          db.dispose();
        }
      });

      test(
        'unfavorited deletion uses submission-time favorite identities',
        () async {
          final previousFolder = appdata.settings['followUpdatesFolder'];
          final previousQuick = appdata.settings['quickFavorite'];
          final favorites = LocalFavoritesManager();
          await favorites.init();
          try {
            final folder = favorites.createFolder('kept');
            favorites.addComic(
              folder,
              FavoriteItem(
                id: 'favorite',
                name: 'Favorite',
                author: '',
                coverPath: '',
                type: ComicType.local,
                tags: [],
              ),
            );
            final writes = [
              manager.addHistory(_history('favorite')),
              manager.addHistory(_history('not-favorite')),
            ];
            final clear = manager.clearUnfavoritedHistory();
            favorites.deleteComicWithId(folder, 'favorite', ComicType.local);
            await Future.wait([...writes, clear]);
            expect(manager.getAll().map((item) => item.id), ['favorite']);
          } finally {
            await favorites.debugWaitForHashedIdsRefresh();
            await appdata.saveData(false);
            favorites.close();
            LocalFavoritesManager.cache = null;
            appdata.settings['followUpdatesFolder'] = previousFolder;
            appdata.settings['quickFavorite'] = previousQuick;
          }
        },
      );

      test('retention and clear run after queued writes', () async {
        final fresh = _history('fresh')..time = DateTime.now();
        await Future.wait([
          manager.addHistory(_history('old')),
          manager.addHistory(fresh),
          manager.clearExpiredHistory(1),
        ]);
        expect(manager.getAll().map((item) => item.id), ['fresh']);
        await Future.wait([
          manager.addHistory(_history('another')),
          manager.clearHistory(),
        ]);
        expect(manager.count(), 0);
      });

      test('drain includes writes submitted by completion listeners', () async {
        var added = false;
        manager.addListener(() {
          if (!added) {
            added = true;
            manager.addHistory(_history('listener'));
          }
        });
        final first = manager.addHistory(_history('first'));
        await manager.waitForAsyncWrites();
        await first;
        expect(manager.hasPendingWrites, isFalse);
        expect(manager.find('listener', ComicType.local), isNotNull);
      });

      test(
        'queued deletion keeps its database after close and reopen',
        () async {
          final writing = manager.addHistory(_history('old-database'));
          final deleting = manager.remove('old-database', ComicType.local);
          manager.close();
          final reopened = Directory('${directory.path}/new')..createSync();
          App.dataPath = reopened.path;
          await manager.init();
          await manager.addHistory(_history('new-database'));
          await Future.wait([writing, deleting]);
          expect(manager.getAll().map((item) => item.id), ['new-database']);
          final old = sqlite3.open('${directory.path}/history.db');
          try {
            expect(old.select('SELECT * FROM history'), isEmpty);
          } finally {
            old.dispose();
          }
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'history copies detach mutable read keys and preserve all stored fields',
    () {
      final original = _history('copy')
        ..group = 3
        ..readDurationMs = 75;
      final copy = original.copy();
      original.readEpisode.add('3-2');
      original.page = 9;
      expect(copy.readEpisode, {'1'});
      expect(copy.page, 2);
      expect(copy.group, 3);
      expect(copy.readDurationMs, 75);
      expect(copy.time, original.time);
      expect(copy.title, original.title);
      expect(copy.subtitle, original.subtitle);
      expect(copy.cover, original.cover);
      expect(copy.maxPage, original.maxPage);
      expect(copy.type, original.type);
      copy.readEpisode.add('other');
      expect(original.readEpisode, {'1', '3-2'});
    },
  );

  test('History.fromMap defaults missing reading duration to zero', () {
    expect(_history('legacy-map').readDurationMs, 0);
  });

  test('refreshHistoryInfo does not wait after final retry failure', () async {
    const sourceKey = 'history_refresh_test_source';
    var attempts = 0;
    final retryDelays = <Duration>[];
    final source = _source(
      sourceKey,
      loadComicInfo: (id) async {
        attempts++;
        return const Res.error('network unavailable');
      },
    );
    ComicSourceManager().add(source);
    addTearDown(() {
      ComicSourceManager().remove(sourceKey);
    });

    final history = History.fromMap({
      'type': ComicType.fromKey(sourceKey).value,
      'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'title': 'Remote Comic',
      'subtitle': 'Author',
      'cover': 'cover.jpg',
      'ep': 1,
      'page': 2,
      'id': 'comic-1',
      'readEpisode': ['1'],
      'max_page': 10,
    });

    final result = await HistoryManager.create().refreshHistoryInfo(
      history,
      retryDelay: (duration) {
        retryDelays.add(duration);
        return Future.value();
      },
    );

    expect(result, isFalse);
    expect(attempts, 3);
    expect(retryDelays, const [Duration(seconds: 2), Duration(seconds: 2)]);
  });

  test(
    'addHistory writes through an isolate-owned sqlite connection',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      await manager.addHistory(_history('comic-1'));

      final saved = manager.find('comic-1', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.page, 2);
      expect(saved.maxPage, 10);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'queued writes capture values and cache only persisted identities',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final submitted = List.generate(5, (index) => _history('comic-$index'));
      final futures = submitted.map(manager.addHistory).toList();
      for (final value in submitted) {
        value.id = 'mutated';
        value.title = 'Not submitted';
        value.page = 99;
        value.readEpisode.add('999');
      }
      await Future.wait(futures);

      expect(manager.count(), 5);
      expect(manager.find('mutated', ComicType.local), isNull);
      for (var i = 0; i < 5; i++) {
        final saved = manager.find('comic-$i', ComicType.local);
        expect(saved, isNotNull);
        expect(saved!.title, 'Title comic-$i');
        expect(saved.page, 2);
        expect(saved.readEpisode, {'1'});
      }
      final durationItem = _history('duration')..group = 2;
      final durationWrite = manager.addReadDuration(
        durationItem,
        const Duration(milliseconds: 80),
      );
      durationItem.id = 'different';
      durationItem.group = 9;
      await durationWrite;
      final savedDuration = manager.find('duration', ComicType.local)!;
      expect(savedDuration.readDurationMs, 80);
      expect(savedDuration.group, 2);
      expect(durationItem.readDurationMs, 0);
      expect(manager.find('different', ComicType.local), isNull);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'waitForAsyncWrites drains queued history writes before close',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final write = manager.addHistory(_history('comic-drained'));
      await manager.waitForAsyncWrites();
      await write;
      var notifications = 0;
      manager.addListener(() => notifications++);
      final lateWrite = manager.addHistory(_history('old-lifetime'));
      manager.close();
      final reopened = Directory('${dataDir.path}/reopened')..createSync();
      App.dataPath = reopened.path;
      await manager.init();
      final beforeCompletion = notifications;
      await lateWrite;
      expect(notifications, beforeCompletion);
      expect(manager.count(), 0);
      expect(manager.find('old-lifetime', ComicType.local), isNull);
      final oldDatabase = sqlite3.open('${dataDir.path}/history.db');
      try {
        expect(
          oldDatabase.select(
            "SELECT id FROM history WHERE id = 'old-lifetime'",
          ),
          hasLength(1),
        );
      } finally {
        oldDatabase.dispose();
      }
      manager.close();
      HistoryManager.cache = null;

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final rows = db.select(
          'select page, max_page from history where id = ?',
          ['comic-drained'],
        );

        expect(rows, hasLength(1));
        expect(rows.first['page'], 2);
        expect(rows.first['max_page'], 10);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init migrates reading duration for an existing history database',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
          id text primary key,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final saved = manager.find('legacy-comic', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.readDurationMs, 0);
      expect(manager.getTotalReadDurationMs(), 0);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'history writes support legacy tables without a unique id constraint',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
          id text,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final existing = _history('legacy-comic')..page = 7;
      await manager.addHistory(existing);
      await manager.addReadDuration(existing, const Duration(seconds: 15));
      await manager.addHistory(_history('new-comic'));
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final existingRows = db.select(
          '''
          select page, read_duration_ms
          from history where id = ? and type = ?;
          ''',
          ['legacy-comic', ComicType.local.value],
        );
        expect(existingRows, hasLength(1));
        expect(existingRows.first['page'], 7);
        expect(existingRows.first['read_duration_ms'], 15000);
        expect(db.select('select count(*) from history;').first[0], 2);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'reading duration accumulates and survives progress upserts',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final first = _history('comic-first');
      final second = _history('comic-second');
      await manager.addHistory(first);
      await manager.addHistory(second);

      await Future.wait([
        manager.addReadDuration(first, const Duration(seconds: 40)),
        manager.addReadDuration(first, const Duration(seconds: 20)),
        manager.addReadDuration(second, const Duration(seconds: 30)),
      ]);
      first.page = 8;
      first.maxPage = 12;
      await manager.addHistory(first);
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final row = db
            .select(
              '''
          select page, max_page, read_duration_ms
          from history where id = ?;
          ''',
              ['comic-first'],
            )
            .first;
        expect(row['page'], 8);
        expect(row['max_page'], 12);
        expect(row['read_duration_ms'], 60000);
      } finally {
        db.dispose();
      }

      expect(manager.getTotalReadDurationMs(), 90000);
      expect(manager.countWithReadDuration(), 2);
      expect(manager.getAllByReadDuration().map((history) => history.id), [
        'comic-first',
        'comic-second',
      ]);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

ComicSource _source(String key, {LoadComicFunc? loadComicInfo}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
