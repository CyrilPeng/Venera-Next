import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/sync/comic_archive_batch.dart';
import 'package:venera_next/features/sync/comic_backup.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Ops ops;
  late BackupConfig config;
  late ComicBackupManager manager;
  late List<String> exports;

  setUp(() {
    root = Directory.systemTemp.createTempSync('archive-batch-');
    App.cachePath = root.path;
    config = _config('/original/');
    ops = _Ops();
    exports = [];
    manager = ComicBackupManager(
      operations: ops,
      readConfig: () => config,
      exportComic: (comic, path) async {
        exports.add(comic.id);
        await File(path).writeAsString('archive-${comic.id}');
      },
    );
  });
  tearDown(() async => root.delete(recursive: true));

  ComicArchiveBatch upload(List<LocalComic> comics) {
    final batch = manager.createBackupBatch(comics);
    addTearDown(batch.dispose);
    return batch;
  }

  test(
    'retry only failed identities and retain original input and counts',
    () async {
      final targets = [_comic('A'), _comic('B'), _comic('C')];
      final batch = upload(targets);
      ops.failUpload.add(batch.items[1].fileName);
      targets.clear();
      await batch.run();
      expect(batch.items.map((item) => item.state), [
        ArchiveItemState.success,
        ArchiveItemState.failed,
        ArchiveItemState.success,
      ]);
      expect(batch.items[1].error.toString(), contains('upload failed'));
      ops.failUpload.clear();
      await batch.run(retryFailed: true);
      expect(batch.count(ArchiveItemState.success), 3);
      expect(batch.count(ArchiveItemState.failed), 0);
      expect(exports, ['A', 'B', 'C', 'B']);
      expect(ops.uploads.map((path) => path.split('/').last), [
        batch.items[0].fileName,
        batch.items[1].fileName,
        batch.items[2].fileName,
        batch.items[1].fileName,
      ]);
      expect(root.listSync(), isEmpty);
    },
  );

  test('single retry leaves other failures untouched', () async {
    final batch = upload([_comic('A'), _comic('B')]);
    ops.failUpload.addAll(batch.items.map((item) => item.fileName));
    await batch.run();
    ops.failUpload.clear();
    await batch.run(retryFailed: true, onlyIndex: 1);
    expect(batch.items[0].state, ArchiveItemState.failed);
    expect(batch.items[1].state, ArchiveItemState.success);
    expect(exports, ['A', 'B', 'B']);
  });

  for (final corrupt in [false, true]) {
    test(
      'lost acknowledgement verifies original bytes, corrupt=$corrupt',
      () async {
        final batch = upload([_comic('A')]);
        ops.loseAcknowledgement = true;
        ops.corrupt = corrupt;
        await batch.run();
        expect(batch.items.single.state, ArchiveItemState.failed);
        ops.loseAcknowledgement = false;
        await batch.run(retryFailed: true);
        expect(
          batch.items.single.state,
          corrupt ? ArchiveItemState.failed : ArchiveItemState.success,
        );
        if (corrupt) {
          expect(batch.items.single.error.toString(), contains('conflicts'));
        }
        expect(ops.uploads, hasLength(1));
        expect(ops.downloads, hasLength(1));
        expect(exports, ['A']);
        expect(root.listSync(), isEmpty);
      },
    );
  }

  test(
    'a pre-existing same name is explicitly unverified, never overwritten',
    () async {
      final batch = upload([_comic('A')]);
      ops.remote['/original/${batch.items.single.fileName}'] = [1];
      await batch.run();
      expect(batch.items.single.state, ArchiveItemState.skipped);
      await batch.run(retryFailed: true, onlyIndex: 0);
      expect(exports, isEmpty);
      expect(ops.uploads, isEmpty);
      expect(BackupResult.fromBatch(batch).success, 0);
    },
  );

  test(
    'same sanitized names within one batch cannot overwrite each other',
    () async {
      final batch = upload([
        _comic('A', title: 'Same'),
        _comic('B', title: 'Same'),
      ]);
      await batch.run();
      expect(batch.count(ArchiveItemState.success), 1);
      expect(batch.count(ArchiveItemState.skipped), 1);
      expect(exports, ['A']);
      expect(ops.uploads, hasLength(1));
    },
  );

  test('retry keeps frozen configuration and filename', () async {
    final batch = upload([_comic('A')]);
    final name = batch.items.single.fileName;
    ops.failUpload.add(name);
    await batch.run();
    config = _config('/replacement/');
    ops.failUpload.clear();
    await batch.run(retryFailed: true);
    expect(batch.items.single.fileName, name);
    expect(ops.uploads, ['/original/$name', '/original/$name']);
    expect(
      ops.configs.every((value) => value.remotePath == '/original/'),
      isTrue,
    );
  });

  test('cancel during export separates cancelled and unstarted rows', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final special = ComicBackupManager(
      operations: ops,
      readConfig: () => config,
      exportComic: (comic, path) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        await File(path).writeAsString(comic.id);
      },
    );
    final batch = special.createBackupBatch([_comic('A'), _comic('B')]);
    addTearDown(batch.dispose);
    final pending = batch.run();
    await entered.future;
    batch.cancel();
    release.complete();
    await pending;
    final result = BackupResult.fromBatch(batch);
    expect(result.cancelled, 1);
    expect(result.notStarted, 1);
    expect(result.failed, 0);
    expect(ops.uploads, isEmpty);
    await batch.run(retryFailed: true);
    expect(ops.uploads, isEmpty);
    await batch.run();
    expect(batch.count(ArchiveItemState.success), 2);
  });

  test(
    'cancel waits for actual upload result and does not start the next',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      ops.uploadGate = () async {
        entered.complete();
        await release.future;
      };
      final batch = upload([_comic('A'), _comic('B')]);
      final pending = batch.run();
      await entered.future;
      batch.cancel();
      expect(batch.running, isTrue);
      expect(root.listSync(), isNotEmpty);
      release.complete();
      await pending;
      expect(batch.items[0].state, ArchiveItemState.success);
      expect(batch.items[1].state, ArchiveItemState.pending);
      expect(root.listSync(), isEmpty);
    },
  );

  test('double run cannot replay a running transfer', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    ops.uploadGate = () async {
      entered.complete();
      await release.future;
    };
    final batch = upload([_comic('A')]);
    final first = batch.run();
    await entered.future;
    await batch.run();
    await batch.run(retryFailed: true);
    expect(ops.uploads, hasLength(1));
    release.complete();
    await first;
    await batch.run();
    expect(exports, ['A']);
  });

  test('cancel during retry lookup does not start another upload', () async {
    final batch = upload([_comic('A')]);
    ops.failUpload.add(batch.items.single.fileName);
    await batch.run();
    ops.failUpload.clear();
    ops.existsGate = () async => batch.cancel();
    await batch.run(retryFailed: true);
    expect(batch.items.single.state, ArchiveItemState.cancelled);
    expect(ops.uploads, hasLength(1));
    expect(root.listSync(), isEmpty);
    ops.existsGate = null;
    await batch.run();
    expect(batch.count(ArchiveItemState.success), 1);
    expect(ops.uploads, hasLength(2));
  });

  test('dispose cancels remaining work without late notifications', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    ops.uploadGate = () async {
      entered.complete();
      await release.future;
    };
    final batch = manager.createBackupBatch([_comic('A'), _comic('B')]);
    var changes = 0;
    batch.addListener(() => changes++);
    final pending = batch.run();
    await entered.future;
    batch.dispose();
    final before = changes;
    release.complete();
    await pending;
    expect(changes, before);
    expect(batch.items[1].state, ArchiveItemState.pending);
    expect(root.listSync(), isEmpty);
  });

  test('setup failure keeps every target identifiable for retry', () async {
    ops.failDirectory = true;
    final batch = upload([_comic('A'), _comic('B')]);
    await batch.run();
    expect(batch.count(ArchiveItemState.failed), 2);
    expect(exports, isEmpty);
    ops.failDirectory = false;
    await batch.run(retryFailed: true);
    expect(batch.count(ArchiveItemState.success), 2);
  });

  test(
    'invalid configuration accounts for all rows and stays isolated',
    () async {
      config = BackupConfig(url: '', user: '', pass: '', remotePath: '/');
      final batch = upload([_comic('A'), _comic('B')]);
      await batch.run();
      expect(batch.count(ArchiveItemState.failed), 2);
      expect(ops.configs, isEmpty);
    },
  );

  test(
    'display diagnostics redact credentials but retain original errors',
    () async {
      ops.uploadError = StateError(
        'https://user:secret-value@example.test/?token=private-token password=secret-value',
      );
      final batch = upload([_comic('A')]);
      await batch.run();
      final error = batch.items.single.error!;
      expect(error, same(ops.uploadError));
      final text = batch.errorText(error);
      expect(text, isNot(contains('secret-value')));
      expect(text, isNot(contains('private-token')));
      expect(text, isNot(contains('user:')));
    },
  );

  ComicArchiveBatch restore({
    Future<void> Function(LocalComic)? registrar,
    Future<LocalComic> Function(
      File, {
      Future<void> Function(LocalComic)? registerComic,
    })?
    importer,
  }) {
    final batch =
        ComicBackupManager(
          operations: ops,
          readConfig: () => config,
          registerImportedComic: registrar ?? (_) async {},
          importComic:
              importer ??
              (file, {registerComic}) async {
                final comic = _comic(file.readAsStringSync());
                await registerComic!(comic);
                return comic;
              },
        ).createRestoreBatch([
          BackupFile(name: 'A.cbz', size: 1, modified: DateTime(2024)),
          BackupFile(name: 'B.cbz', size: 1, modified: DateTime(2024)),
        ]);
    addTearDown(batch.dispose);
    return batch;
  }

  test('download retry does not import successful rows twice', () async {
    ops.failDownload.add('B.cbz');
    final saved = <String>[];
    final batch = restore(registrar: (comic) async => saved.add(comic.id));
    await batch.run();
    expect(saved, ['A.cbz']);
    ops.failDownload.clear();
    await batch.run(retryFailed: true);
    expect(saved, ['A.cbz', 'B.cbz']);
    expect(batch.count(ArchiveItemState.success), 2);
    expect(root.listSync(), isEmpty);
  });

  for (final state in PersistenceCommitState.values) {
    test('registration replay respects commit state ${state.name}', () async {
      var failRegistration = true;
      var calls = 0;
      final batch = restore(
        registrar: (_) async {
          calls++;
          if (failRegistration) {
            throw PersistenceFailure(
              commitState: state,
              cause: StateError('registration'),
              stackTrace: StackTrace.current,
            );
          }
        },
      );
      await batch.run();
      expect(
        batch.items.every((item) => item.canRetry),
        state == PersistenceCommitState.notCommitted,
      );
      failRegistration = false;
      await batch.run(retryFailed: true);
      expect(calls, state == PersistenceCommitState.notCommitted ? 4 : 2);
    });
  }

  test(
    'unclassified failure after registration cannot duplicate imports',
    () async {
      var calls = 0;
      final batch = restore(
        registrar: (_) async {
          calls++;
        },
        importer: (file, {registerComic}) async {
          await registerComic!(_comic('A'));
          throw StateError('post-import cleanup failed');
        },
      );
      await batch.run();
      expect(batch.items.every((item) => !item.canRetry), isTrue);
      expect(batch.items.first.error, isA<PersistenceFailure>());
      await batch.run(retryFailed: true);
      expect(calls, 2);
    },
  );
}

BackupConfig _config(String path) => BackupConfig(
  url: 'https://example.test',
  user: 'user',
  pass: 'secret-value',
  remotePath: path,
);

LocalComic _comic(String id, {String? title}) => LocalComic(
  id: id,
  title: title ?? id,
  subtitle: '',
  tags: const [],
  directory: id,
  chapters: null,
  cover: 'cover.jpg',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime(2024),
);

class _Ops implements ComicBackupWebDavOps {
  final remote = <String, List<int>>{};
  final uploads = <String>[];
  final downloads = <String>[];
  final configs = <BackupConfig>[];
  final failUpload = <String>{};
  final failDownload = <String>{};
  bool failDirectory = false;
  bool loseAcknowledgement = false;
  bool corrupt = false;
  Object? uploadError;
  Future<void> Function()? uploadGate;
  Future<void> Function()? existsGate;

  @override
  Future<void> test(BackupConfig config) async {}
  @override
  Future<void> ensureDirectory(BackupConfig config) async {
    if (failDirectory) throw StateError('mkdir failed');
  }

  @override
  Future<List<BackupFile>> list(BackupConfig config) async {
    configs.add(config);
    return [
      for (final entry in remote.entries)
        BackupFile(
          name: entry.key.split('/').last,
          size: entry.value.length,
          modified: DateTime(2024),
        ),
    ];
  }

  @override
  Future<bool> exists(BackupConfig config, String path) async {
    configs.add(config);
    await existsGate?.call();
    return remote.containsKey(path);
  }

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String local,
    String path,
  ) async {
    configs.add(config);
    uploads.add(path);
    await uploadGate?.call();
    if (uploadError != null) throw uploadError!;
    if (failUpload.contains(path.split('/').last)) {
      throw StateError('upload failed');
    }
    if (remote.containsKey(path)) throw StateError('412');
    remote[path] = await File(local).readAsBytes();
    if (corrupt) remote[path]![0] ^= 1;
    if (loseAcknowledgement) throw StateError('response lost');
  }

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String path,
    String local,
  ) async {
    downloads.add(path);
    if (failDownload.contains(path.split('/').last)) {
      throw StateError('download failed');
    }
    await File(
      local,
    ).writeAsBytes(remote[path] ?? path.split('/').last.codeUnits);
  }

  @override
  Future<void> deleteFile(BackupConfig config, String path) async =>
      remote.remove(path);
}
