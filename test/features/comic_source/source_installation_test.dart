import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_installation.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/parser.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

void main() {
  late _Downloads downloads;
  late _Manager manager;
  late SourceInstallations queue;
  late dynamic repositories;
  setUp(() {
    downloads = _Downloads();
    manager = _Manager();
    queue = SourceInstallations(
      createClient: () => Dio()..httpClientAdapter = downloads,
      repositories: SourceRepositories.instance,
      manager: manager,
    );
    repositories = appdata.settings['comicSourceRepositories'];
    appdata.settings['comicSourceRepositories'] = <Map<String, String>>[];
  });
  tearDown(() async {
    for (final task in queue.tasks) {
      queue.cancel(task);
    }
    downloads.completeAll();
    await queue.closeAndWait();
    appdata.settings['comicSourceRepositories'] = repositories;
  });
  Future<void> settle() => pumpEventQueue(times: 30);

  test(
    'cleared failed install keeps its original cause during release retries',
    () async {
      final cause = StateError('install failed');
      manager.failWith = cause;
      final file = _SelectedScript()..releaseError = StateError('release');
      final task = queue.enqueueFile(
        'failed.js',
        Uint8List(0),
        selection: file,
      );
      await settle();
      final stack = task.stackTrace;
      expect(task.cause, same(cause));
      queue.clearFinished();
      await settle();
      expect(queue.tasks, isEmpty);
      await expectLater(
        queue.closeAndWait(),
        throwsA(
          isA<SourceInstallationCloseFailure>().having(
            (e) => e.failures.single.error,
            'file cleanup',
            isA<FileSelectionCleanupFailure>()
                .having((e) => e.operationError, 'install cause', same(cause))
                .having((e) => e.operationStack, 'install stack', same(stack)),
          ),
        ),
      );
      file.releaseError = null;
      await queue.closeAndWait();
      expect(file.reads, 1);
      expect(manager.scripts, hasLength(1));
    },
  );

  test(
    'clear waits late cancelled read error before reporting cleanup failure',
    () async {
      final gate = Completer<Uint8List>();
      final cause = StateError('late read');
      final stack = StackTrace.fromString('late read origin');
      final file = _SelectedScript()
        ..readAction = ((_) => gate.future)
        ..releaseError = StateError('release');
      final task = queue.enqueueFile('late.js', Uint8List(0), selection: file);
      await settle();
      queue.cancel(task);
      queue.clearFinished();
      await settle();
      expect(file.releases, 0);
      final close = expectLater(
        queue.closeAndWait(),
        throwsA(
          isA<SourceInstallationCloseFailure>().having(
            (e) => e.failures.single.error,
            'late read diagnostic',
            isA<FileSelectionCleanupFailure>()
                .having((e) => e.operationError, 'cause', same(cause))
                .having((e) => e.operationStack, 'stack', same(stack)),
          ),
        ),
      );
      gate.completeError(cause, stack);
      await close;
      file.releaseError = null;
      await queue.closeAndWait();
      expect(file.reads, 1);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'old and retried read failures remain ordered after row removal',
    () async {
      final old = Completer<Uint8List>();
      final errors = [StateError('old read'), StateError('new read')];
      final stacks = [
        StackTrace.fromString('old read origin'),
        StackTrace.fromString('new read origin'),
      ];
      final file = _SelectedScript()
        ..readAction = ((attempt) => attempt == 1
            ? old.future
            : Future<Uint8List>.error(errors[1], stacks[1]))
        ..releaseError = StateError('release');
      final task = queue.enqueueFile('retry.js', Uint8List(0), selection: file);
      await settle();
      queue.cancel(task);
      queue.retry(task);
      await settle();
      expect(task.cause, same(errors[1]));
      queue.clearFinished();
      await settle();
      expect(file.releases, 0);
      old.completeError(errors[0], stacks[0]);
      await settle();
      SourceInstallationCloseFailure? failure;
      try {
        await queue.closeAndWait();
      } on SourceInstallationCloseFailure catch (error) {
        failure = error;
      }
      final cleanup =
          failure!.failures.single.error as FileSelectionCleanupFailure;
      final attempts =
          cleanup.operationError! as SourceInstallationAttemptFailure;
      expect(attempts.failures.map((e) => e.attempt), [1, 2]);
      expect(attempts.failures.map((e) => e.error), errors);
      expect(attempts.failures.map((e) => e.stack), stacks);
      file.releaseError = null;
      await queue.closeAndWait();
      expect(file.reads, 2);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'successful retry does not erase earlier cause from failed file release',
    () async {
      final cause = StateError('first read');
      final stack = StackTrace.fromString('first read origin');
      final file = _SelectedScript()
        ..readAction = (attempt) async {
          if (attempt == 1) Error.throwWithStackTrace(cause, stack);
          return Uint8List.fromList('// valid'.codeUnits);
        }
        ..releaseError = StateError('release');
      final task = queue.enqueueFile('retry.js', Uint8List(0), selection: file);
      await settle();
      queue.retry(task);
      await settle();
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(task.cause, isNull);
      await expectLater(
        queue.closeAndWait(),
        throwsA(
          isA<SourceInstallationCloseFailure>().having(
            (e) => e.failures.single.error,
            'history',
            isA<FileSelectionCleanupFailure>()
                .having((e) => e.operationError, 'earlier cause', same(cause))
                .having((e) => e.operationStack, 'earlier stack', same(stack)),
          ),
        ),
      );
      file.releaseError = null;
      await queue.closeAndWait();
      expect(file.reads, 2);
      expect(manager.installs, hasLength(1));
    },
  );

  test(
    'clear retains a canceled selected file until its actual read settles',
    () async {
      final file = _SelectedScript()..readGate = Completer<void>();
      final task = queue.enqueueFile('held.js', Uint8List(0), selection: file);
      await settle();
      expect(file.reads, 1);
      queue.cancel(task);
      queue.clearFinished();
      await settle();
      expect(file.released, isFalse);
      var closed = false;
      final closing = queue.closeAndWait().then((_) => closed = true);
      await settle();
      expect(closed, isFalse);
      file.readGate!.complete();
      await closing;
      expect(file.released, isTrue);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'selected file cleanup failure can retry close without replaying install',
    () async {
      final file = _SelectedScript()..releaseError = StateError('release');
      queue.enqueueFile('held.js', Uint8List(0), selection: file);
      await settle();
      expect(manager.installs, hasLength(1));
      await expectLater(
        queue.closeAndWait(),
        throwsA(isA<SourceInstallationCloseFailure>()),
      );
      file.releaseError = null;
      await queue.closeAndWait();
      expect(manager.installs, hasLength(1));
      expect(file.reads, 1);
      expect(file.released, isTrue);
    },
  );

  test(
    'deduplication keeps original selected file and leaves rejected handle to caller',
    () async {
      final first = _SelectedScript()..readGate = Completer<void>();
      final second = _SelectedScript();
      final task = queue.enqueueFile('same.js', Uint8List(0), selection: first);
      final duplicate = queue.enqueueFile(
        'same.js',
        Uint8List(0),
        selection: second,
      );
      expect(duplicate, same(task));
      expect(duplicate.selection, same(first));
      await second.dispose();
      expect(first.released, isFalse);
      first.readGate!.complete();
      await settle();
      queue.clearFinished();
      await settle();
      expect(first.released, isTrue);
    },
  );

  test(
    'close before pumping rejects new work and never opens a client',
    () async {
      final task = queue.enqueueUrl('https://example.test/queued.js');
      final closing = queue.closeAndWait();
      expect(queue.closeAndWait(), same(closing));
      expect(task.phase, SourceInstallPhase.canceled);
      expect(() => queue.enqueueUrl(task.url!), throwsStateError);
      expect(queue.canRetry(task), isFalse);
      await closing;
      expect(downloads.requests, isEmpty);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'cleared canceled attempts still delay close after a newer retry ends',
    () async {
      final task = queue.enqueueUrl('https://example.test/retired.js');
      await settle();
      queue.cancel(task);
      queue.retry(task);
      await settle();
      downloads.complete(1);
      await settle();
      expect(task.phase, SourceInstallPhase.succeeded);
      queue.clearFinished();
      expect(queue.tasks, isEmpty);
      var closed = false;
      final closing = queue.closeAndWait().then((_) => closed = true);
      await settle();
      expect(closed, isFalse);
      downloads.complete(0);
      await closing;
      expect(manager.installs, hasLength(1));
    },
  );

  test(
    'close retains a file read without installing its late contents',
    () async {
      final read = Completer<Uint8List>();
      final task = queue.enqueueFile(
        'held.js',
        Uint8List(0),
        readFile: () => read.future,
      );
      await settle();
      var closed = false;
      final closing = queue.closeAndWait().then((_) => closed = true);
      await settle();
      expect(closed, isFalse);
      read.complete(Uint8List.fromList(utf8.encode('// late')));
      await closing;
      expect(task.phase, SourceInstallPhase.canceled);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'close waits manager admission and cancels before atomic install',
    () async {
      final admission = Completer<void>();
      manager.admission = admission.future;
      final task = queue.enqueuePreviewedScript(
        name: 'waiting',
        contents: '// source',
      );
      await settle();
      expect(task.phase, SourceInstallPhase.waiting);
      var closed = false;
      final closing = queue.closeAndWait().then((_) => closed = true);
      await settle();
      expect(closed, isFalse);
      admission.complete();
      await closing;
      expect(task.phase, SourceInstallPhase.canceled);
      expect(manager.installs, isEmpty);
    },
  );

  test(
    'listener close retains admitted installation and does not lend data access',
    () async {
      final commit = Completer<void>();
      manager.commit = commit.future;
      manager.inDataPreparation = true;
      Future<void>? closing;
      queue.addListener(() {
        expect(AppDataOperations.instance.sharingScope, isNull);
        if (queue.tasks.any((t) => t.phase == SourceInstallPhase.installing)) {
          closing = queue.closeAndWait();
        }
      });
      final task = queue.enqueuePreviewedScript(
        name: 'committing',
        contents: '// source',
      );
      await settle();
      expect(closing, isNotNull);
      expect(task.canCancel, isFalse);
      var closed = false;
      final waited = closing!.then((_) => closed = true);
      await settle();
      expect(closed, isFalse);
      commit.complete();
      await waited;
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(manager.installs, hasLength(1));
    },
  );

  test(
    'ordinary installation failure preserves error and stack without blocking close',
    () async {
      final error = StateError('invalid source');
      manager.failWith = error;
      final task = queue.enqueuePreviewedScript(
        name: 'failure',
        contents: '// source',
      );
      await settle();
      expect(task.cause, same(error));
      expect(task.stackTrace, isNotNull);
      await queue.closeAndWait();
    },
  );

  test(
    'three concurrent downloads and queued cancellation preserve the limit',
    () async {
      final tasks = List.generate(
        5,
        (i) => queue.enqueueUrl('https://example.test/$i.js'),
      );
      await settle();
      expect(downloads.requests.length, 3);
      expect(tasks[3].phase, SourceInstallPhase.queued);
      queue.cancel(tasks[3]);
      downloads.complete(0);
      await settle();
      expect(downloads.requests.length, 4);
      expect(downloads.requests.last.uri.path, '/4.js');
      expect(tasks[3].phase, SourceInstallPhase.canceled);
      expect(tasks.first.phase, SourceInstallPhase.succeeded);
    },
  );

  test(
    'cancel frees a slot and a late old response cannot complete a retry',
    () async {
      final task = queue.enqueueUrl('https://example.test/a.js');
      await settle();
      queue.cancel(task);
      queue.retry(task);
      await settle();
      expect(downloads.requests.length, 2);
      downloads.complete(0);
      await settle();
      expect(task.phase, SourceInstallPhase.downloading);
      expect(manager.installs, isEmpty);
      downloads.complete(1);
      await settle();
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(manager.installs.length, 1);
      expect(queue.canRetry(task), isFalse);
    },
  );

  test('failed download can retry and clears its previous error', () async {
    final task = queue.enqueueUrl('https://example.test/a.js');
    await settle();
    downloads.complete(0, status: 503);
    await settle();
    expect(task.phase, SourceInstallPhase.failed);
    expect(task.errorSummary, contains('503'));
    queue.retry(task);
    expect(task.error, isNull);
    await settle();
    downloads.complete(1);
    await settle();
    expect(task.phase, SourceInstallPhase.succeeded);
  });

  test(
    'previewed URL installs the inspected bytes without downloading twice',
    () async {
      final task = queue.enqueuePreviewedScript(
        name: 'Preview',
        contents: '// inspected',
        url: 'https://example.test/source',
      );
      await settle();
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(downloads.requests, isEmpty);
      expect(manager.scripts, ['// inspected']);
      expect(manager.installs.single.kind, 'url');
      expect(manager.installs.single.url, 'https://example.test/source');
    },
  );

  test('retrying a failed previewed URL downloads the latest script', () async {
    manager.failNext = true;
    final task = queue.enqueuePreviewedScript(
      name: 'Preview',
      contents: '// broken',
      url: 'https://example.test/source',
    );
    await settle();
    expect(task.phase, SourceInstallPhase.failed);
    expect(downloads.requests, isEmpty);
    queue.retry(task);
    await settle();
    expect(downloads.requests, hasLength(1));
    downloads.complete(0);
    await settle();
    expect(task.phase, SourceInstallPhase.succeeded);
    expect(manager.scripts, ['// broken', '// source']);
  });

  const repository = SourceRepository(
    id: 'r',
    name: 'Repo',
    url: 'https://example.test/index.json',
  );
  const entry = SourceCatalogEntry(
    key: 'source',
    name: 'Source',
    version: '1.0.0',
    url: 'https://example.test/a.js',
  );
  test(
    'same key across repositories and same URL share an active task',
    () async {
      final task = queue.enqueueRepository(repository, entry);
      final other = queue.enqueueRepository(
        const SourceRepository(
          id: 'other',
          name: 'Other',
          url: 'https://other.test/index.json',
        ),
        const SourceCatalogEntry(
          key: 'source',
          name: 'Other',
          version: '2.0.0',
          url: 'https://other.test/a.js',
        ),
      );
      expect(identical(task, other), isTrue);
      expect(identical(task, queue.enqueueUrl(entry.url)), isTrue);
      await settle();
      expect(downloads.requests.length, 1);
    },
  );

  for (final change in ['removed', 'changed']) {
    test('repository $change before commit rejects installation', () async {
      appdata.settings['comicSourceRepositories'] = [repository.toJson()];
      final task = queue.enqueueRepository(repository, entry);
      await settle();
      appdata.settings['comicSourceRepositories'] = change == 'removed'
          ? []
          : [
              {...repository.toJson(), 'url': 'https://new.test/index.json'},
            ];
      downloads.complete(0);
      await settle();
      expect(task.phase, SourceInstallPhase.failed);
      expect(manager.installs, isEmpty);
      expect(task.error, contains('Repository changed'));
    });
  }

  test(
    'file import uses the install flow without a network download',
    () async {
      final bytes = Uint8List.fromList(utf8.encode('// source'));
      final task = queue.enqueueFile('local.js', bytes);
      expect(identical(task, queue.enqueueFile('local.js', bytes)), isTrue);
      await settle();
      expect(downloads.requests, isEmpty);
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(task.sourceKey, 'installed');
      expect(task.name, 'Installed source');
      expect(manager.installs.single.kind, 'file');
    },
  );

  test(
    'file retry reads edited contents instead of the failed snapshot',
    () async {
      var content = 'broken';
      manager.failNext = true;
      final task = queue.enqueueFile(
        'local.js',
        Uint8List.fromList(utf8.encode(content)),
        readFile: () async => Uint8List.fromList(utf8.encode(content)),
      );
      await settle();
      expect(task.phase, SourceInstallPhase.failed);
      content = 'fixed';
      queue.retry(task);
      await settle();
      expect(manager.scripts, ['broken', 'fixed']);
      expect(task.phase, SourceInstallPhase.succeeded);
    },
  );

  test(
    'duplicate imports can reload the edited file and recover from a failed replacement',
    () async {
      manager.sources['installed'] = _Source();
      var content = 'draft';
      manager.failWith = SourceAlreadyInstalledException('installed');
      final task = queue.enqueueFile(
        'local.js',
        Uint8List.fromList(utf8.encode(content)),
        readFile: () async => Uint8List.fromList(utf8.encode(content)),
      );
      await settle();
      expect(task.sourceKey, 'installed');
      expect(queue.canRetry(task), isFalse);
      expect(queue.canReplace(task), isTrue);
      manager.failNext = true;
      queue.replace(task);
      await settle();
      expect(task.phase, SourceInstallPhase.failed);
      expect(manager.find('installed'), isNotNull);
      content = 'fixed';
      queue.replace(task);
      expect(queue.canReplace(task), isFalse);
      await settle();
      expect(manager.replacements, ['draft', 'fixed']);
      expect(task.phase, SourceInstallPhase.succeeded);
      expect(queue.canReplace(task), isTrue);
    },
  );
}

class _Downloads implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final responses = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final response = Completer<ResponseBody>();
    responses.add(response);
    // Deliberately keep the old response alive: Dio must ignore it after cancel.
    return response.future;
  }

  void complete(int index, {int status = 200}) =>
      responses[index].complete(ResponseBody.fromString('// source', status));
  void completeAll() {
    for (final response in responses) {
      if (!response.isCompleted) {
        response.complete(ResponseBody.fromString('// source', 200));
      }
    }
  }

  @override
  void close({bool force = false}) {}
}

class _Manager extends Fake implements ComicSourceManager {
  final sources = <String, ComicSource>{};
  @override
  ComicSource? find(String key) => sources[key];
  final installs = <SourceOrigin>[];
  final scripts = <String>[];
  final replacements = <String>[];
  Object? failWith;
  bool failNext = false;
  Future<void>? admission;
  Future<void>? commit;
  bool inDataPreparation = false;
  @override
  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) async {
    await admission;
    if (inDataPreparation) {
      await AppDataOperations.instance.prepare(() async => beforeInstall());
    } else {
      beforeInstall();
    }
    await commit;
    scripts.add(js);
    if (failWith != null) {
      final error = failWith!;
      failWith = null;
      throw error;
    }
    if (failNext) {
      failNext = false;
      throw 'invalid script';
    }
    installs.add(origin);
    return _Source();
  }

  @override
  Future<void> replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) async {
    validate();
    replacements.add(js);
    if (failNext) {
      failNext = false;
      throw 'invalid replacement';
    }
  }
}

class _Source extends Fake implements ComicSource {
  @override
  void bindDataOwner() {}

  @override
  Future<void> closeDataWrites() async {}

  @override
  void disposeRuntimeCallbacks() {}

  @override
  String get key => 'installed';
  @override
  String get name => 'Installed source';
}

class _SelectedScript extends FileSelection {
  _SelectedScript() : super('selected.js');
  Completer<void>? readGate;
  Object? releaseError;
  Future<Uint8List> Function(int)? readAction;
  int reads = 0;
  int releases = 0;
  bool released = false;
  @override
  Future<Uint8List> readAsBytes() => withFile((_) async {
    reads++;
    if (readAction != null) return readAction!(reads);
    await readGate?.future;
    return Uint8List.fromList(utf8.encode('// selected source'));
  });
  @override
  Future<void> dispose() async {
    releases++;
    if (releaseError != null) throw releaseError!;
    await super.dispose();
    released = true;
  }
}
