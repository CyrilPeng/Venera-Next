import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart' show copyDirectory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory destination;
  late LocalManager manager;
  late _DatabaseProxy database;
  late LocalComic cached;
  late String source;
  var failJournal = false;
  var armed = false;
  var commits = 0;
  var fault = 'commit';
  var failRollback = false;
  var journalReads = 0;
  var faultConsumed = false;
  final acknowledgement = StateError('commit acknowledgement failed');

  LocalComic comic(String id, String directory) => LocalComic(
    id: id,
    title: id,
    subtitle: '',
    tags: [],
    directory: directory,
    chapters: null,
    cover: '1.jpg',
    comicType: ComicType.local,
    downloadedChapters: [],
    createdAt: DateTime(2024),
  );
  setUp(() async {
    root = Directory.systemTemp.createTempSync('storage-authority-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    failJournal = false;
    armed = false;
    commits = 0;
    fault = 'commit';
    failRollback = false;
    journalReads = 0;
    faultConsumed = false;
    manager = LocalManager.independent(
      openDatabase: (path) {
        database = _DatabaseProxy(
          sqlite3.open(path),
          beforeExecute: (sql) {
            if (failRollback && sql == 'ROLLBACK;') {
              throw StateError('rollback unavailable');
            }
          },
          afterExecute: (sql) {
            if (!armed || faultConsumed) return;
            if ((fault == 'prepareRollback' &&
                    sql.startsWith('INSERT INTO local_storage_relocation')) ||
                (fault == 'commitRollback' &&
                    sql.startsWith('UPDATE comics SET directory'))) {
              faultConsumed = true;
              throw acknowledgement;
            }
            if (sql != 'COMMIT;') return;
            commits++;
            if (commits != (fault == 'prepare' ? 1 : 2)) return;
            faultConsumed = true;
            if (fault == 'missingJournal') {
              database.actual.execute('DELETE FROM local_storage_relocation');
            }
            failJournal = fault == 'commit' || fault == 'prepare';
            throw acknowledgement;
          },
          beforeSelect: (sql) {
            if (armed &&
                commits == 2 &&
                sql == 'SELECT * FROM local_storage_relocation') {
              journalReads++;
              if (fault == 'oneRead' && journalReads > 1) {
                throw StateError('second journal read unavailable');
              }
            }
            if (failJournal &&
                sql == 'SELECT * FROM local_storage_relocation') {
              throw StateError('journal temporarily unavailable');
            }
          },
        );
        return database;
      },
      initializeSources: () async {},
    );
    await manager.init();
    source = manager.path;
    final directory = Directory(p.join(source, 'Book'))..createSync();
    File(p.join(directory.path, '1.jpg')).writeAsStringSync('original page');
    await manager.add(comic('1', directory.path));
    await manager.add(comic('2', 'Book'));
    cached = manager.find('2', ComicType.local)!;
    destination = Directory(p.join(root.path, 'moved'))..createSync();
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    manager.dispose();
    root.deleteSync(recursive: true);
  });
  Future<void> uncertain() async {
    armed = true;
    expect(
      await manager.setNewPath(destination.path),
      contains('commit acknowledgement failed'),
    );
    expect(
      database.actual
          .select("SELECT directory FROM comics WHERE id = '1'")
          .single['directory'],
      p.join(destination.path, 'Book'),
    );
    expect(File(p.join(root.path, 'local_path')).existsSync(), isFalse);
    for (final library in [source, destination.path]) {
      expect(
        File(p.join(library, 'Book', '1.jpg')).readAsStringSync(),
        'original page',
      );
    }
  }

  test(
    'unknown committed root blocks new records until authority is recovered',
    () async {
      await uncertain();
      await expectLater(
        manager.add(comic('3', 'later')),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(database.actual.select('SELECT id FROM comics'), hasLength(2));
    },
  );
  test(
    'accepted directory creation blocks migration until its filesystem work settles',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final parent = Zone.current;
      final allocation = IOOverrides.runZoned(
        () => manager.allocateDownloadDirectory(
          'held',
          ComicType.local,
          'Delayed',
        ),
        createDirectory: (name) {
          final actual = parent.run(() => Directory(name));
          return p.equals(name, p.join(source, 'Delayed'))
              ? _HeldDirectory(actual, entered, release.future)
              : actual;
        },
      );
      try {
        await entered.future;
        expect(await manager.setNewPath(destination.path), isNotNull);
        expect(manager.path, source);
        expect(destination.listSync(), isEmpty);
      } finally {
        release.complete();
        await allocation;
      }
      expect(await manager.setNewPath(destination.path), isNull);
      expect(
        Directory(p.join(destination.path, 'Delayed')).existsSync(),
        isTrue,
      );
    },
  );
  test(
    'failed recovery keeps the fence and a later retry restores both cached and new access',
    () async {
      await uncertain();
      expect(manager.requiresStorageRecovery, isTrue);
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(manager.recoverStorage(), throwsStateError);
        expect(
          () => manager.find('1', ComicType.local),
          throwsA(isA<LocalComicStorageBusy>()),
        );
        expect(() => cached.baseDir, throwsA(isA<LocalComicStorageBusy>()));
      }
      failJournal = false;
      armed = false;
      await manager.recoverStorage();
      expect(manager.requiresStorageRecovery, isFalse);
      expect(manager.path, destination.path);
      expect(cached.baseDir, p.join(destination.path, 'Book'));
      expect(cached.coverFile.readAsStringSync(), 'original page');
      await manager.add(comic('3', 'later'));
      final allocation = await manager.allocateDownloadDirectory(
        '3',
        ComicType.local,
        'later',
      );
      expect(p.isWithin(destination.path, allocation.directory.path), isTrue);
      expect(
        database.actual.select('SELECT * FROM local_storage_relocation'),
        isEmpty,
      );
    },
  );

  test(
    'existing move entry retries recovery without also starting a second move',
    () async {
      await uncertain();
      failJournal = false;
      armed = false;
      final next = Directory(p.join(root.path, 'next'))..createSync();
      expect(
        await manager.setNewPath(next.path),
        contains('recovery completed'),
      );
      expect(manager.path, destination.path);
      expect(next.listSync(), isEmpty);
      expect(await manager.setNewPath(next.path), isNull);
      expect(cached.baseDir, p.join(next.path, 'Book'));
    },
  );

  for (final stage in ['prepareRollback', 'commitRollback']) {
    test(
      '$stage remains fenced until the original transaction rolls back',
      () async {
        fault = stage;
        armed = true;
        failRollback = true;
        expect(
          await manager.setNewPath(destination.path),
          contains('rollback unavailable'),
        );
        expect(database.autocommit, isFalse);
        expect(() => manager.path, throwsA(isA<LocalComicStorageBusy>()));
        await expectLater(manager.recoverStorage(), throwsStateError);
        expect(manager.requiresStorageRecovery, isTrue);
        failRollback = false;
        armed = false;
        await manager.recoverStorage();
        expect(database.autocommit, isTrue);
        expect(manager.path, source);
        expect(
          database.actual
              .select("SELECT directory FROM comics WHERE id = '1'")
              .single['directory'],
          p.join(source, 'Book'),
        );
        expect(
          database.actual.select('SELECT * FROM local_storage_relocation'),
          isEmpty,
        );
        await manager.add(comic('3', 'later'));
        expect(cached.coverFile.readAsStringSync(), 'original page');
      },
    );
  }

  test(
    'unknown preparation acknowledgement recovers the source without changing rows',
    () async {
      fault = 'prepare';
      armed = true;
      expect(
        await manager.setNewPath(destination.path),
        contains('commit acknowledgement'),
      );
      expect(manager.requiresStorageRecovery, isTrue);
      expect(
        database.actual
            .select("SELECT directory FROM comics WHERE id = '1'")
            .single['directory'],
        p.join(source, 'Book'),
      );
      failJournal = false;
      armed = false;
      await manager.recoverStorage();
      expect(manager.path, source);
      expect(cached.baseDir, p.join(source, 'Book'));
    },
  );

  test('confirmed rollback immediately restores the original root', () async {
    fault = 'commitRollback';
    armed = true;
    expect(
      await manager.setNewPath(destination.path),
      contains('commit acknowledgement'),
    );
    expect(manager.requiresStorageRecovery, isFalse);
    expect(manager.path, source);
    await manager.add(comic('3', 'later'));
  });

  test(
    'confirmed commit publishes its rows without requiring a second journal read',
    () async {
      fault = 'oneRead';
      armed = true;
      expect(
        await manager.setNewPath(destination.path),
        contains('commit acknowledgement'),
      );
      expect(journalReads, 1);
      expect(manager.requiresStorageRecovery, isFalse);
      expect(manager.path, destination.path);
      expect(cached.baseDir, p.join(destination.path, 'Book'));
    },
  );

  test(
    'missing journal after a commit attempt cannot release the fence using the old root',
    () async {
      fault = 'missingJournal';
      armed = true;
      expect(
        await manager.setNewPath(destination.path),
        contains('commit acknowledgement'),
      );
      armed = false;
      await expectLater(manager.recoverStorage(), throwsStateError);
      expect(manager.requiresStorageRecovery, isTrue);
      expect(() => manager.path, throwsA(isA<LocalComicStorageBusy>()));
    },
  );

  test(
    'missing authoritative target keeps access blocked until files are restored',
    () async {
      await uncertain();
      failJournal = false;
      armed = false;
      destination.deleteSync(recursive: true);
      await expectLater(
        manager.recoverStorage(),
        throwsA(isA<FileSystemException>()),
      );
      expect(manager.requiresStorageRecovery, isTrue);
      destination.createSync();
      await copyDirectory(Directory(source), destination);
      await manager.recoverStorage();
      expect(manager.path, destination.path);
      expect(cached.coverFile.readAsStringSync(), 'original page');
    },
  );
  test('changed journal roots cannot release the original attempt', () async {
    await uncertain();
    failJournal = false;
    armed = false;
    final other = Directory(p.join(root.path, 'unrelated'))..createSync();
    database.actual.execute('UPDATE local_storage_relocation SET source = ?', [
      other.path,
    ]);
    await expectLater(manager.recoverStorage(), throwsStateError);
    expect(manager.requiresStorageRecovery, isTrue);
    database.actual.execute('UPDATE local_storage_relocation SET source = ?', [
      source,
    ]);
    await manager.recoverStorage();
    expect(manager.path, destination.path);
  });

  test(
    'reopening the database recovers new models without reviving old unknown ones',
    () async {
      await uncertain();
      manager.dispose();
      final reopened = LocalManager.independent(
        openDatabase: sqlite3.open,
        initializeSources: () async {},
      );
      try {
        await reopened.init();
        expect(reopened.path, destination.path);
        expect(
          reopened.find('2', ComicType.local)!.coverFile.readAsStringSync(),
          'original page',
        );
        expect(() => cached.baseDir, throwsA(isA<LocalComicStorageBusy>()));
      } finally {
        await reopened.pendingDownloadTaskWrites;
        reopened.dispose();
      }
    },
  );

  test(
    'mirror finishing failure retains known access and a pending journal',
    () async {
      Directory(p.join(root.path, 'local_path')).createSync();
      expect(await manager.setNewPath(destination.path), isNotNull);
      expect(manager.requiresStorageRecovery, isFalse);
      expect(manager.path, destination.path);
      await manager.recoverStorage();
      expect(manager.requiresStorageRecovery, isFalse);
      expect(
        database.actual.select('SELECT * FROM local_storage_relocation'),
        hasLength(1),
      );
      await manager.add(comic('3', 'later'));
    },
  );

  test(
    'download admissions and destructive operations are rejected before side effects',
    () async {
      await uncertain();
      final task = _Task();
      expect(
        () => manager.addTask(task),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.resumeDownload(task),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.restorePausedDownloads([task]),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.restoreDownloadingTasks(),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.completeTask(task),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(task.resumes, 0);
      expect(manager.downloadingTasks, isEmpty);
      await expectLater(
        manager.deleteComic(cached),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.remove('1', ComicType.local),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(database.actual.select('SELECT * FROM comics'), hasLength(2));
      // Queue persistence/exit remains possible; no blocked task was admitted.
      await manager.saveCurrentDownloadingTasks();
      await manager.pendingDownloadTaskWrites;
      failJournal = false;
      armed = false;
      await manager.recoverStorage();
      manager.addTask(task);
      expect(task.resumes, 1);
      await manager.cancelDownload(task);
    },
  );

  test(
    'a different manager stays usable and cannot release the original fence',
    () async {
      await uncertain();
      final otherData = Directory(p.join(root.path, 'other'))..createSync();
      App.dataPath = otherData.path;
      final other = LocalManager.independent(
        openDatabase: sqlite3.open,
        initializeSources: () async {},
      );
      try {
        await other.init();
        await other.add(comic('1', 'another'));
        expect(other.count, 1);
        await other.recoverStorage();
        expect(manager.requiresStorageRecovery, isTrue);
        failJournal = false;
        armed = false;
        await manager.recoverStorage();
        expect(manager.path, destination.path);
        expect(other.path, p.join(otherData.path, 'local'));
      } finally {
        await other.pendingDownloadTaskWrites;
        other.dispose();
      }
    },
  );
  test(
    'new imports do not enter their file-work callback while the original library is fenced',
    () async {
      await uncertain();
      var entered = false;
      final service = ComicImportService(
        localManager: () => manager,
        favoritesManager: LocalFavoritesManager.new,
      );
      await expectLater(
        service.runImport((_) async => entered = true),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(entered, isFalse);
      failJournal = false;
      armed = false;
      await manager.recoverStorage();
      await service.runImport((_) async => entered = true);
      expect(entered, isTrue);
    },
  );
  test(
    'unknown committed root cannot be exposed as a directory to a new writer',
    () async {
      await uncertain();
      expect(() => manager.path, throwsA(isA<LocalComicStorageBusy>()));
      expect(() => manager.directory, throwsA(isA<LocalComicStorageBusy>()));
    },
  );
  test(
    'unknown root blocks directory allocation before creating output',
    () async {
      await uncertain();
      await expectLater(
        manager.allocateDownloadDirectory('3', ComicType.local, 'later'),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(Directory(p.join(source, 'later')).existsSync(), isFalse);
    },
  );
  test(
    'cached relative covers stop reading the old copy while authority is unknown',
    () async {
      await uncertain();
      expect(() => cached.coverFile, throwsA(isA<LocalComicStorageBusy>()));
      await expectLater(
        manager.getImages('2', ComicType.local, 1),
        throwsA(isA<LocalComicStorageBusy>()),
      );
    },
  );
}

class _DatabaseProxy extends Fake implements Database {
  _DatabaseProxy(
    this.actual, {
    this.beforeExecute,
    this.afterExecute,
    this.beforeSelect,
  });
  final Database actual;
  final void Function(String)? beforeExecute;
  final void Function(String)? afterExecute;
  final void Function(String)? beforeSelect;
  @override
  bool get autocommit => actual.autocommit;
  @override
  int get updatedRows => actual.updatedRows;
  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    beforeExecute?.call(sql);
    actual.execute(sql, parameters);
    afterExecute?.call(sql);
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    beforeSelect?.call(sql);
    return actual.select(sql, parameters);
  }

  @override
  void dispose() => actual.dispose();
}

class _Task extends DownloadTask {
  int resumes = 0;
  @override
  Future<void> get pendingCleanup => Future.value();
  @override
  String get id => '3';
  @override
  ComicType get comicType => ComicType.local;
  @override
  String get title => 'later';
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  bool get isPaused => resumes == 0;
  @override
  bool get isError => false;
  @override
  int get speed => 0;
  @override
  double get progress => 0;
  @override
  void pause() {}
  @override
  void resume() => resumes++;
  @override
  void cancel() {}
  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => throw UnimplementedError();
}

class _HeldDirectory extends Fake implements Directory {
  _HeldDirectory(this.actual, this.entered, this.release);
  final Directory actual;
  final Completer<void> entered;
  final Future<void> release;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) async {
    entered.complete();
    await release;
    return actual.create(recursive: recursive);
  }
}
