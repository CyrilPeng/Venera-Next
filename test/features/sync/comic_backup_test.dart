import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  setUp(() {
    appdata.settings['backupWebdav'] = [];
    appdata.settings['backupWebdavPath'] = '/venera_backup/';
    appdata.settings['backupWebdavSyncEnabled'] = false;
    App.dataPath = Directory.systemTemp.createTempSync('venera_data').path;
    App.cachePath = Directory.systemTemp.createTempSync('venera_cache').path;
    ComicBackupManager.exportComic = null;
    ComicBackupManager.importComic = null;
    ComicBackupManager.registerImportedComic = null;
    ComicBackupManager.ops = _FakeBackupOps();
  });

  tearDown(() {
    ComicBackupManager.exportComic = null;
    ComicBackupManager.importComic = null;
    ComicBackupManager.registerImportedComic = null;
    ComicBackupManager.resetOps();
  });

  group('BackupConfig', () {
    test('is invalid when WebDAV archive config is empty', () {
      final config = BackupConfig.fromSettings();

      expect(config.isValid, isFalse);
      expect(config.remotePath, '/venera_backup/');
    });

    test('normalizes remote path with leading and trailing slash', () {
      appdata.settings['backupWebdav'] = [
        'https://example.com/dav',
        'u',
        ' p ',
      ];
      appdata.settings['backupWebdavPath'] = 'archive';

      final config = BackupConfig.fromSettings();

      expect(config.isValid, isTrue);
      expect(config.pass, 'p');
      expect(config.remotePath, '/archive/');
      expect(config.remoteFilePath('A.cbz'), '/archive/A.cbz');
    });
  });

  group('archive WebDAV config sync setting', () {
    test('does not sync archive WebDAV config when disabled', () async {
      appdata.settings['backupWebdavSyncEnabled'] = false;
      appdata.settings['backupWebdav'] = [
        'https://local.example/dav',
        'local',
        'pass',
      ];
      appdata.settings['backupWebdavPath'] = '/local/';

      await appdata.syncData({
        'settings': {
          'backupWebdavSyncEnabled': true,
          'backupWebdav': ['https://remote.example/dav', 'remote', 'pass'],
          'backupWebdavPath': '/remote/',
        },
        'searchHistory': [],
      });

      // backupWebdavSyncEnabled itself syncs so remote toggle propagates
      expect(appdata.settings['backupWebdavSyncEnabled'], isTrue);
      // but backupWebdav/backupWebdavPath are blocked because sync was disabled BEFORE
      // this syncData call (backupWebdavSyncEnabled was false when processing started)
      expect(appdata.settings['backupWebdav'], [
        'https://local.example/dav',
        'local',
        'pass',
      ]);
      expect(appdata.settings['backupWebdavPath'], '/local/');
    });

    test('syncs archive WebDAV config when enabled locally', () async {
      appdata.settings['backupWebdavSyncEnabled'] = true;
      appdata.settings['backupWebdav'] = [
        'https://local.example/dav',
        'local',
        'pass',
      ];
      appdata.settings['backupWebdavPath'] = '/local/';

      await appdata.syncData({
        'settings': {
          'backupWebdavSyncEnabled': true,
          'backupWebdav': ['https://remote.example/dav', 'remote', 'pass'],
          'backupWebdavPath': '/remote/',
        },
        'searchHistory': [],
      });

      expect(appdata.settings['backupWebdavSyncEnabled'], isTrue);
      expect(appdata.settings['backupWebdav'], [
        'https://remote.example/dav',
        'remote',
        'pass',
      ]);
      expect(appdata.settings['backupWebdavPath'], '/remote/');
    });
  });

  group('ComicBackupManager.listBackups', () {
    test('lists only cbz files sorted by modified time desc', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = 'archive';
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 2, 1);
      ComicBackupManager.ops = _FakeBackupOps(
        listResult: [
          BackupFile(name: 'not-a-comic.txt', size: 10, modified: newer),
          BackupFile(name: 'old.cbz', size: 20, modified: older),
          BackupFile(name: 'new.CBZ', size: 30, modified: newer),
        ],
      );

      final result = await ComicBackupManager.listBackups();

      expect(result.success, isTrue);
      expect(result.data.map((e) => e.name), ['new.CBZ', 'old.cbz']);
      expect(
        (ComicBackupManager.ops as _FakeBackupOps).listedPath,
        '/archive/',
      );
    });

    test('tests connection through configured WebDAV path', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = 'archive';
      ComicBackupManager.ops = _FakeBackupOps();

      final result = await ComicBackupManager.testConnection(
        BackupConfig.fromSettings(),
      );

      expect(result.success, isTrue);
      expect(
        (ComicBackupManager.ops as _FakeBackupOps).testedPath,
        '/archive/',
      );
    });
  });

  group('ComicBackupManager.backup', () {
    test(
      'counts success and skipped files and deletes temporary exports',
      () async {
        appdata.settings['backupWebdav'] = [
          'https://example.com/dav',
          'u',
          'p',
        ];
        final uploadedPaths = <String>[];
        final dupComic = _comic('Dup');
        final freshComic = _comic('Fresh');
        final dupFileName = ComicBackupManager.backupFileName(dupComic);
        final fakeOps = _FakeBackupOps(
          listResult: [
            BackupFile(name: dupFileName, size: 0, modified: DateTime(2024)),
          ],
        );
        ComicBackupManager.ops = fakeOps;
        ComicBackupManager.exportComic = (comic, path) async {
          File(path).writeAsStringSync(comic.title);
        };

        final result = await ComicBackupManager.backup([
          dupComic,
          freshComic,
        ], onProgress: (_, _, _) {});
        uploadedPaths.addAll(fakeOps.uploadedRemotePaths);

        expect(result.success, 1);
        expect(result.skipped, 1);
        expect(result.failed, 0);
        expect(uploadedPaths, hasLength(1));
        expect(uploadedPaths.single, startsWith('/venera_backup/Fresh_'));
        expect(uploadedPaths.single, endsWith('.cbz'));
        expect(Directory(App.cachePath).listSync().whereType<File>(), isEmpty);
      },
    );

    test('stops before next comic when cancelled', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      var exportCount = 0;
      ComicBackupManager.ops = _FakeBackupOps();
      ComicBackupManager.exportComic = (comic, path) async {
        exportCount++;
        File(path).writeAsStringSync(comic.title);
      };

      final result = await ComicBackupManager.backup([
        _comic('One'),
        _comic('Two'),
      ], isCancelled: () => exportCount > 0);

      expect(result.success, 1);
      expect(result.skipped, 0);
      expect(result.failed, 0);
      expect(exportCount, 1);
    });
  });

  group('ComicBackupManager.restore', () {
    test('downloads and imports selected backups', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      final importedPaths = <String>[];
      final registeredComics = <LocalComic>[];
      final fakeOps = _FakeBackupOps();
      ComicBackupManager.ops = fakeOps;
      ComicBackupManager.importComic = (path) async {
        importedPaths.add(path);
        return _comic('Imported');
      };
      ComicBackupManager.registerImportedComic = (comic) async {
        registeredComics.add(comic);
      };

      final result = await ComicBackupManager.restore([
        BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
      ]);

      expect(result.success, 1);
      expect(result.failed, 0);
      expect(fakeOps.downloadedRemotePaths, ['/venera_backup/A.cbz']);
      expect(importedPaths.single, endsWith('A.cbz'));
      expect(registeredComics.single.title, 'Imported');
      expect(File(importedPaths.single).existsSync(), isFalse);
    });

    test('deletes a backup file through WebDAV', () async {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      final fakeOps = _FakeBackupOps();
      ComicBackupManager.ops = fakeOps;

      final result = await ComicBackupManager.deleteBackup(
        BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
      );

      expect(result.success, isTrue);
      expect(fakeOps.deletedRemotePaths, ['/venera_backup/A.cbz']);
    });
  });
  group('backup failure ownership', () {
    setUp(() {
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
    });

    for (final stage in ['test', 'list', 'delete']) {
      test('$stage preserves the original cause and stack in Res', () async {
        final original = StateError('native request failed');
        final trace = StackTrace.fromString('original-$stage');
        ComicBackupManager.ops = _FakeBackupOps(
          failAt: stage,
          failure: original,
          failureStack: trace,
        );
        final result = switch (stage) {
          'test' => await ComicBackupManager.testConnection(
            BackupConfig.fromSettings(),
          ),
          'list' => await ComicBackupManager.listBackups(),
          _ => await ComicBackupManager.deleteBackup(
            BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
          ),
        };
        expect(result.error, isTrue);
        expect(result.failure?.cause, same(original));
        expect(result.failure?.stackTrace, same(trace));
      });
    }

    test(
      'listing cleanup failure cannot become a successful fallback',
      () async {
        final original = StateError('list failed');
        final trace = StackTrace.fromString('original-list');
        final cleanup = StateError('native cleanup failed');
        final failure = WebDavClientCleanupFailure(
          cause: original,
          stackTrace: trace,
          failures: [(stage: 'native', error: cleanup, stack: trace)],
        );
        final ops = _FakeBackupOps(
          failAt: 'list',
          failure: failure,
          failureStack: trace,
        );
        ComicBackupManager.ops = ops;
        ComicBackupManager.exportComic = (_, _) async =>
            fail('must not export');
        final result = await ComicBackupManager.backup([_comic('One')]);
        expect(result.success, 0);
        expect(result.failed, 1);
        expect(result.failures.single.error, same(failure));
        expect(result.failures.single.stack, same(trace));
        expect(ops.existsCalls, 0);
        expect(ops.uploadedRemotePaths, isEmpty);
      },
    );

    test('ordinary listing failure still uses the per-file fallback', () async {
      final ops = _FakeBackupOps(
        failAt: 'list',
        failure: StateError('offline'),
      );
      ComicBackupManager.ops = ops;
      ComicBackupManager.exportComic = (_, path) async =>
          File(path).writeAsString('archive');
      final result = await ComicBackupManager.backup([_comic('One')]);
      expect(result.success, 1);
      expect(result.failed, 0);
      expect(ops.existsCalls, 1);
      expect(ops.uploadedRemotePaths, hasLength(1));
    });

    for (final stage in ['upload', 'download']) {
      test('$stage failure survives batch result translation', () async {
        final original = StateError('native failure');
        final trace = StackTrace.fromString('original-$stage');
        ComicBackupManager.ops = _FakeBackupOps(
          failAt: stage,
          failure: original,
          failureStack: trace,
        );
        ComicBackupManager.exportComic = (_, path) async =>
            File(path).writeAsString('archive');
        final result = stage == 'upload'
            ? await ComicBackupManager.backup([_comic('One')])
            : await ComicBackupManager.restore([
                BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
              ]);
        expect(result.success, 0);
        expect(result.failed, 1);
        expect(result.failures.single.error, same(original));
        expect(result.failures.single.stack, same(trace));
        expect(result.errors.single, contains(original.toString()));
      });
    }
  });
}

LocalComic _comic(String title) {
  return LocalComic(
    id: title.toLowerCase(),
    title: title,
    subtitle: '',
    tags: const [],
    directory: title,
    chapters: null,
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: const [],
    createdAt: DateTime(2024),
  );
}

class _FakeBackupOps implements ComicBackupWebDavOps {
  _FakeBackupOps({
    this.listResult = const [],
    this.failAt,
    this.failure,
    this.failureStack,
  });

  final List<BackupFile> listResult;
  final String? failAt;
  final Object? failure;
  final StackTrace? failureStack;
  var existsCalls = 0;
  void check(String stage) {
    if (stage == failAt) {
      Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
    }
  }

  String? listedPath;
  String? testedPath;
  final uploadedRemotePaths = <String>[];
  final downloadedRemotePaths = <String>[];
  final deletedRemotePaths = <String>[];

  @override
  Future<void> test(BackupConfig config) async {
    check('test');
    testedPath = config.remotePath;
  }

  @override
  Future<List<BackupFile>> list(BackupConfig config) async {
    check('list');
    listedPath = config.remotePath;
    return listResult;
  }

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async {
    existsCalls++;
    return false;
  }

  @override
  Future<void> ensureDirectory(BackupConfig config) async {}

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) async {
    check('upload');
    uploadedRemotePaths.add(remotePath);
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) async {
    check('download');
    downloadedRemotePaths.add(remotePath);
    File(localPath).writeAsStringSync(remotePath);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) async {
    check('delete');
    deletedRemotePaths.add(remotePath);
  }
}
