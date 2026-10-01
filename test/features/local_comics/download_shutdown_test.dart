import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  setUp(() {
    LocalManager.resetForTesting();
    root = Directory.systemTemp.createTempSync('download-shutdown-');
    App.dataPath = root.path;
  });
  tearDown(() async {
    await LocalManager().pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  test(
    'exit preparation drains first, snapshots latest state and holds scheduling',
    () async {
      final manager = LocalManager();
      final gate = Completer<void>();
      final task = _Task()..cleanup = gate.future;
      manager.restorePausedDownloads([task]);
      manager.resumeDownload(task);
      final preparing = LocalManager.prepareDownloadsForExit();
      expect(task.isPaused, isTrue);
      await pumpEventQueue();
      expect(File('${root.path}/downloading_tasks.json').existsSync(), isFalse);
      task.path = 'allocated-before-drain';
      gate.complete();
      final release = await preparing;
      final snapshot =
          jsonDecode(
                File('${root.path}/downloading_tasks.json').readAsStringSync(),
              )
              as List;
      expect(snapshot.single['path'], 'allocated-before-drain');
      manager.resumeDownload(task);
      expect(task.isPaused, isTrue);
      release();
      manager.resumeDownload(task);
      expect(task.isPaused, isFalse);
    },
  );

  test(
    'snapshot failure releases suspension and permits exit preparation retry',
    () async {
      final manager = LocalManager();
      final task = _Task();
      manager.restorePausedDownloads([task]);
      final obstruction = Directory('${root.path}/downloading_tasks.json')
        ..createSync();
      await expectLater(
        LocalManager.prepareDownloadsForExit(),
        throwsA(isA<FileSystemException>()),
      );
      manager.resumeDownload(task);
      expect(task.isPaused, isFalse);
      obstruction.deleteSync();
      final release = await LocalManager.prepareDownloadsForExit();
      expect(task.isPaused, isTrue);
      expect(File('${root.path}/downloading_tasks.json').existsSync(), isTrue);
      release();
    },
  );
}

class _Task extends DownloadTask {
  bool paused = true;
  Future<void>? cleanup;
  @override
  String get id => 'shutdown';
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
  Map<String, dynamic> toJson() => {'id': id, 'path': path};
  @override
  LocalComic toLocalComic() => throw UnsupportedError('shutdown fixture');
}
