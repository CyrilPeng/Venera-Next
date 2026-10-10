import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late LocalManager manager;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('storage-coordination-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    manager = LocalManager();
    await manager.init();
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.current?.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'queued paused or active downloads protect migration and recovery',
    () async {
      final task = _Task('queued');
      manager.restorePausedDownloads([task]);
      final oldPath = manager.path;
      final destination = Directory('${root.path}/destination')..createSync();
      var scanned = false;
      expect(await manager.setNewPath(destination.path), isNotNull);
      await expectLater(
        manager.runWithExclusiveStorage(() async => scanned = true),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      manager.resumeDownload(task);
      expect(await manager.setNewPath(destination.path), isNotNull);
      expect(manager.path, oldPath);
      expect(destination.listSync(), isEmpty);
      expect(scanned, isFalse);
      expect(task.isPaused, isFalse);
    },
  );

  test(
    'migration drains canceled work and blocks new admissions until completion',
    () async {
      final gate = Completer<void>();
      final task = _Task('canceled')..cleanup = gate.future;
      manager.restorePausedDownloads([task]);
      final canceled = manager.cancelDownload(task);
      File('${manager.path}/keep.txt').writeAsStringSync('keep');
      final destination = Directory('${root.path}/destination')..createSync();
      final migrating = manager.setNewPath(destination.path);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await migrating;
      });
      await pumpEventQueue();
      expect(destination.listSync(), isEmpty);
      expect(() => manager.addTask(_Task('too-early')), throwsStateError);
      gate.complete();
      await canceled;
      expect(await migrating, isNull);
      expect(manager.path, destination.path);
      expect(File('${destination.path}/keep.txt').readAsStringSync(), 'keep');
      final next = _Task('after');
      manager.addTask(next);
      expect(next.isPaused, isFalse);
    },
  );

  test(
    'failed exclusive work releases both download and import ownership',
    () async {
      await expectLater(
        manager.runWithExclusiveStorage(
          () async => throw StateError('scan failed'),
        ),
        throwsStateError,
      );
      expect(
        await LocalComicStorageGuard.instance.runImport(
          () async => 'available',
        ),
        'available',
      );
      final task = _Task('retry');
      manager.addTask(task);
      expect(task.isPaused, isFalse);
    },
  );

  test(
    'exit waits for storage work before acquiring its own suspension',
    () async {
      final gate = Completer<void>();
      final mutating = manager.runWithExclusiveStorage(() => gate.future);
      final preparing = LocalManager.prepareDownloadsForExit();
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await mutating;
        (await preparing)();
      });
      var prepared = false;
      preparing.then((_) => prepared = true);
      await pumpEventQueue();
      expect(prepared, isFalse);
      expect(File('${root.path}/downloading_tasks.json').existsSync(), isFalse);
      gate.complete();
      await mutating;
      final release = await preparing;
      expect(() => manager.addTask(_Task('during-exit')), throwsStateError);
      release();
      final next = _Task('after-exit');
      manager.addTask(next);
      expect(next.isPaused, isFalse);
    },
  );
}

class _Task extends DownloadTask {
  _Task(this.id);
  @override
  final String id;
  bool paused = true;
  Future<void>? cleanup;
  @override
  ComicType get comicType => const ComicType(17);
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  bool get isPaused => paused;
  @override
  bool get isError => false;
  @override
  int get speed => 0;
  @override
  double get progress => 0;
  @override
  Future<void> get pendingCleanup => cleanup ?? Future.value();
  @override
  void pause() => paused = true;
  @override
  void resume() => paused = false;
  @override
  void cancel() => pause();
  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => throw UnsupportedError('coordination fixture');
}
