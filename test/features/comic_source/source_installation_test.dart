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

void main() {
  late _Downloads downloads;
  late _Manager manager;
  late SourceInstallations queue;
  late dynamic repositories;
  setUp(() {
    downloads = _Downloads();
    manager = _Manager();
    queue = SourceInstallations.forTesting(
      client: Dio()..httpClientAdapter = downloads,
      manager: manager,
    );
    repositories = appdata.settings['comicSourceRepositories'];
    appdata.settings['comicSourceRepositories'] = <Map<String, String>>[];
  });
  tearDown(() async {
    for (final task in queue.tasks) {
      queue.cancel(task);
    }
    await pumpEventQueue();
    queue.dispose();
    appdata.settings['comicSourceRepositories'] = repositories;
  });
  Future<void> settle() => pumpEventQueue(times: 30);

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
      final registry = ComicSourceManager();
      registry.add(_Source());
      addTearDown(() => registry.remove('installed'));
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
      expect(registry.find('installed'), isNotNull);
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
  @override
  void close({bool force = false}) {}
}

class _Manager extends Fake implements ComicSourceManager {
  final installs = <SourceOrigin>[];
  final scripts = <String>[];
  final replacements = <String>[];
  Object? failWith;
  bool failNext = false;
  @override
  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) async {
    beforeInstall();
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
  String get key => 'installed';
  @override
  String get name => 'Installed source';
}
