import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

FavoriteItem _comic(String id) => FavoriteItem(
  id: id,
  name: id,
  author: '',
  coverPath: '',
  type: ComicType.local,
  tags: [],
);

void main() {
  late Directory root;
  late LocalFavoritesManager manager;
  late AppdataImportCheckpoint before;
  setUp(() async {
    before = appdata.captureImportCheckpoint();
    root = Directory.systemTemp.createTempSync('favorite-settings-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalFavoritesManager.cache = null;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['readLaterFolder'] = null;
    manager = LocalFavoritesManager();
    await manager.init();
  });
  tearDown(() async {
    appdata.registerSyncDataRequestHandler(null);
    await manager.closeAndWait();
    LocalFavoritesManager.cache = null;
    await appdata.restoreImportCheckpoint(before, persist: false);
    root.deleteSync(recursive: true);
  });

  test(
    'initialization rechecks a same-name table replacement while queued',
    () async {
      await manager.closeAndWait();
      final entered = Completer<void>();
      final release = Completer<void>();
      final editing = IOOverrides.runWithIOOverrides(
        () => appdata.updateSettings(
          (draft) => draft['cacheSize'] = 818,
          sync: false,
        ),
        _FileHooks(
          beforeWrite: (_, _) async {
            entered.complete();
            await release.future;
          },
        ),
      );
      await entered.future;
      final opening = manager.init();
      final db = sqlite3.open('${root.path}/local_favorite.db');
      final repo = FavoritesRepository(db);
      final tracking = LocalFavoritesManager.trackingFolderName;
      try {
        expect(repo.isPreparedForFollowUpdates(tracking), isTrue);
        repo.deleteFolder(tracking);
        repo.createFolder(tracking);
        expect(repo.isPreparedForFollowUpdates(tracking), isFalse);
        release.complete();
        await Future.wait([editing, opening]);
        expect(repo.isPreparedForFollowUpdates(tracking), isTrue);
        expect(appdata.settings['followUpdatesFolder'], tracking);
      } finally {
        if (!release.isCompleted) release.complete();
        db.dispose();
      }
    },
  );

  test(
    'committed read-later addition publishes caches despite failed settings save',
    () async {
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      final checked = isA<PersistenceFailure>().having(
        (e) => e.commitState,
        'SQL state',
        PersistenceCommitState.committed,
      );
      var notifications = 0;
      void listener() => notifications++;
      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));
      await expectLater(
        manager.setReadLater(
          _comic('first'),
          included: true,
          folderName: 'Later',
        ),
        throwsA(checked),
      );
      expect(manager.readLaterFolder, 'Later');
      expect(manager.folderComics('Later'), 1);
      expect(manager.isExist('first', ComicType.local), isTrue);
      expect(notifications, 1);
      blocked.deleteSync();
      await manager.setReadLater(
        _comic('second'),
        included: true,
        folderName: 'Later',
      );
      await manager.setReadLater(
        _comic('first'),
        included: true,
        folderName: 'Later',
      );
      expect(manager.getReadLaterComics().map((e) => e.id), [
        'second',
        'first',
      ]);
      expect(manager.folderNames.where((e) => e.startsWith('Later')), [
        'Later',
      ]);
      final data = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(data['settings']['readLaterFolder'], 'Later');
    },
  );

  test(
    'committed read-later removal publishes identity and counts on save failure',
    () async {
      await manager.setReadLater(
        _comic('first'),
        included: true,
        folderName: 'Later',
      );
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      try {
        await expectLater(
          manager.setReadLater(
            _comic('first'),
            included: false,
            folderName: 'Later',
          ),
          throwsA(
            isA<PersistenceFailure>().having(
              (e) => e.commitState,
              'state',
              PersistenceCommitState.committed,
            ),
          ),
        );
        expect(manager.folderComics('Later'), 0);
        expect(manager.isExist('first', ComicType.local), isFalse);
      } finally {
        blocked.deleteSync();
      }
      await manager.setReadLater(
        _comic('first'),
        included: false,
        folderName: 'Later',
      );
      expect(manager.getReadLaterComics(), isEmpty);
    },
  );

  test(
    'unchanged initialization needs no write and failed repair really retries',
    () async {
      await manager.closeAndWait();
      final blocked = Directory('${root.path}/appdata.json.tmp')..createSync();
      try {
        await manager.init();
        await manager.closeAndWait();
        appdata.settings['quickFavorite'] = 'missing';
        await expectLater(manager.init(), throwsA(isA<FileSystemException>()));
        expect(appdata.settings['quickFavorite'], isNull);
        // The previous failure already changed memory. The second attempt must
        // still write, rather than treating identical memory as durable success.
        await expectLater(manager.init(), throwsA(isA<FileSystemException>()));
      } finally {
        blocked.deleteSync();
      }
      await manager.init();
      final data = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(data['settings']['quickFavorite'], isNull);
    },
  );

  test(
    'initialization preserves queued selection and prepares it before repair notification',
    () async {
      await manager.createFolder('late');
      await manager.addComic('late', _comic('unused'));
      await manager.closeAndWait();
      appdata.settings['quickFavorite'] = 'missing';
      final entered = Completer<void>();
      final release = Completer<void>();
      final editing = IOOverrides.runWithIOOverrides(
        () => appdata.updateSettings(
          (draft) => draft['cacheSize'] = 817,
          sync: false,
        ),
        _FileHooks(
          beforeWrite: (_, _) async {
            entered.complete();
            await release.future;
          },
        ),
      );
      await entered.future;
      final selecting = appdata.updateSettings(
        (draft) => draft['followUpdatesFolder'] = 'late',
        sync: false,
      );
      var checkedSchema = false;
      void listener() {
        if (appdata.settings['quickFavorite'] != null) return;
        final db = sqlite3.open('${root.path}/local_favorite.db');
        try {
          expect(
            db.select('PRAGMA table_info("late")').map((e) => e['name']),
            contains('has_new_update'),
          );
          checkedSchema = true;
        } finally {
          db.dispose();
        }
      }

      appdata.settings.addListener(listener);
      try {
        final opening = manager.init();
        release.complete();
        await Future.wait([editing, selecting, opening]);
        expect(checkedSchema, isTrue);
        expect(appdata.settings['followUpdatesFolder'], 'late');
        expect(appdata.settings['cacheSize'], 817);
        await manager.updateUpdateTime('late', 'unused', ComicType.local, 'v1');
      } finally {
        appdata.settings.removeListener(listener);
      }
    },
  );

  test(
    'successful clear reports backup cleanup failure without restoring old database',
    () async {
      await manager.createFolder('old');
      await manager.addComic('old', _comic('original'));
      final failure = FileSystemException('backup locked');
      await expectLater(
        IOOverrides.runWithIOOverrides(
          manager.clearAll,
          _FileHooks(
            beforeDelete: (path) {
              if (path.contains('.favorite_clear_') &&
                  path.endsWith('local_favorite.db')) {
                throw failure;
              }
            },
          ),
        ),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (e) => e.commitState,
                'state',
                PersistenceCommitState.committed,
              )
              .having(
                (e) => e.cause,
                'original cleanup failure',
                same(failure),
              ),
        ),
      );
      expect(manager.folderNames, [LocalFavoritesManager.trackingFolderName]);
      expect(manager.getAllComics(), isEmpty);
      final backup = root.listSync().whereType<Directory>().singleWhere(
        (e) => e.path.contains('.favorite_clear_'),
      );
      final db = sqlite3.open('${backup.path}/local_favorite.db');
      try {
        expect(db.select('SELECT id FROM old').single['id'], 'original');
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'clear preserves the original error after a fully successful recovery',
    () async {
      await manager.createFolder('old');
      await manager.addComic('old', _comic('original'));
      await appdata.updateSettings((draft) {
        draft['quickFavorite'] = 'old';
        draft['followUpdatesFolder'] = 'old';
      }, sync: false);
      final failure = FileSystemException('one failed write');
      var writes = 0;
      await expectLater(
        IOOverrides.runWithIOOverrides(
          manager.clearAll,
          _FileHooks(
            beforeWrite: (_, _) async {
              if (++writes == 1) throw failure;
            },
          ),
        ),
        throwsA(same(failure)),
      );
      expect(manager.getFolderComics('old').single.id, 'original');
      expect(appdata.settings['quickFavorite'], 'old');
      final data = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(data['settings']['quickFavorite'], 'old');
    },
  );

  test(
    'failed clear restoration retains backup and reports both errors',
    () async {
      await manager.createFolder('old');
      await manager.addComic('old', _comic('original'));
      appdata.settings['quickFavorite'] = 'old';
      final failure = FileSystemException('initial save failed');
      final restoreFailure = FileSystemException('restore rename failed');
      var writes = 0;
      await expectLater(
        IOOverrides.runWithIOOverrides(
          manager.clearAll,
          _FileHooks(
            beforeWrite: (_, _) async {
              if (++writes == 1) throw failure;
            },
            beforeRename: (path) {
              if (path.contains('.favorite_clear_')) throw restoreFailure;
            },
          ),
        ),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (e) => e.commitState,
                'state',
                PersistenceCommitState.unknown,
              )
              .having((e) => e.cause, 'initial failure', same(failure))
              .having(
                (e) => e.cleanupFailures.single.error,
                'restore failure',
                same(restoreFailure),
              ),
        ),
      );
      expect(() => manager.folderNames, throwsStateError);
      final backup = root.listSync().whereType<Directory>().singleWhere(
        (e) => e.path.contains('.favorite_clear_'),
      );
      final db = sqlite3.open('${backup.path}/local_favorite.db');
      try {
        expect(db.select('SELECT id FROM old').single['id'], 'original');
      } finally {
        db.dispose();
      }
    },
  );
}

final class _FileHooks extends IOOverrides {
  _FileHooks({this.beforeWrite, this.beforeDelete, this.beforeRename});
  final Future<void> Function(String, String)? beforeWrite;
  final void Function(String)? beforeDelete;
  final void Function(String)? beforeRename;
  @override
  File createFile(String path) => _HookedFile(super.createFile(path), this);
}

class _HookedFile implements File {
  _HookedFile(this.raw, this.hooks);
  final File raw;
  final _FileHooks hooks;
  @override
  String get path => raw.path;
  @override
  Directory get parent => raw.parent;
  @override
  bool existsSync() => raw.existsSync();
  @override
  Future<bool> exists() => raw.exists();
  @override
  File renameSync(String newPath) {
    hooks.beforeRename?.call(path);
    return raw.renameSync(newPath);
  }

  @override
  void deleteSync({bool recursive = false}) {
    hooks.beforeDelete?.call(path);
    raw.deleteSync(recursive: recursive);
  }

  @override
  Future<File> rename(String path) => raw.rename(path);
  @override
  Future<File> copy(String path) => raw.copy(path);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      raw.delete(recursive: recursive);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await hooks.beforeWrite?.call(path, contents);
    return raw.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
