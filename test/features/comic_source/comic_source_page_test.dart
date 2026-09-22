import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_repository_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  late Directory dataDir;
  late _SourceRequests requests;
  late List<String> messages;
  late Map<String, dynamic> previousSettings;
  late bool previousLogMuted;
  final scenarios = <({String name, WidgetTesterCallback body})>[];
  const repository = SourceRepository(
    id: 'repo',
    name: 'Repo',
    url: 'https://example.test/repo/index.json',
  );

  void sourceScenario(String name, WidgetTesterCallback body) =>
      scenarios.add((name: name, body: body));
  void setUpScenario() {
    dataDir = Directory.systemTemp.createTempSync('venera-source-update-');
    Directory('${dataDir.path}/comic_source').createSync();
    App.dataPath = dataDir.path;
    previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
    appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
    appdata.settings['language'] = 'en-US';
    previousLogMuted = Log.isMuted;
    Log.isMuted = true;
    requests = _SourceRequests();
    messages = [];
    Dio createDio() => Dio()..httpClientAdapter = requests;
    ComicSourcePage.debugCreateDio = createDio;
    SourceRepositories.debugCreateDio = createDio;
    registerShowMessageHandler((context, message) => messages.add(message));
  }

  void tearDownScenario() {
    ComicSourceManager().remove('installed_source');
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    ComicSourcePage.debugCreateDio = null;
    SourceRepositories.debugCreateDio = null;
    registerShowMessageHandler((context, message) {});
    Log.isMuted = previousLogMuted;
    dataDir.deleteSync(recursive: true);
  }

  Future<void> pumpPage(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: child ?? const Scaffold(),
      ),
    );
  }

  ComicSource install({bool linked = false}) {
    final source = _installedSource(
      '${dataDir.path}/comic_source/installed.js',
    );
    ComicSourceManager().add(source);
    File(source.filePath).writeAsStringSync('original content');
    if (linked) {
      appdata.settings['comicSourceRepositories'] = [repository.toJson()];
      appdata.settings['comicSourceOrigins'] = {
        source.key: const SourceOrigin(
          kind: 'repository',
          repositoryId: 'repo',
          url: 'https://example.test/repo/installed.js',
        ).toJson(),
      };
    }
    return source;
  }

  String catalog({String name = 'Installed Source'}) => jsonEncode([
    {
      'key': 'installed_source',
      'name': name,
      'version': '1.1.0',
      'fileName': 'installed.js',
    },
  ]);

  for (final linked in [false, true]) {
    sourceScenario('cancel script download and retry immediately: linked=$linked', (
      tester,
    ) async {
      await pumpPage(tester);
      final source = install(linked: linked);
      final update = ComicSourcePage.update(source);
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      if (linked) {
        requests.items.single.reply(catalog());
        await _pumpUntil(tester, () => requests.items.length == 2);
      }
      final request = requests.items.last;
      final count = requests.items.length;
      await tester.tap(find.text('Cancel'));
      // Retry before the old request's cleanup runs; it must not clear the new lock.
      final retry = ComicSourcePage.update(source);
      await _pumpUntil(tester, () => requests.items.length == count + 1);
      expect(request.cancelled, isTrue);
      request.reply('late cancelled response must not replace the script');
      await update;
      await ComicSourcePage.update(source);
      await tester.pump();
      expect(requests.items, hasLength(count + 1));
      expect(find.text('Loading'), findsOneWidget);
      expect(ComicSourceManager().find(source.key), same(source));
      expect(File(source.filePath).readAsStringSync(), 'original content');
      expect(messages, isEmpty);
      // Cancel the retry too; for linked sources it is still querying the catalog.
      await tester.tap(find.text('Cancel'));
      await _pumpUntil(tester, () => requests.items.last.cancelled);
      await retry;
      await tester.pump();
      expect(find.text('Loading'), findsNothing);
      expect(File(source.filePath).readAsStringSync(), 'original content');
    });
  }

  sourceScenario(
    'batch update reports a source whose update is already running',
    (tester) async {
      await pumpPage(tester);
      final source = install();
      var finished = false;
      final running = ComicSourcePage.update(source, false).catchError((_) {});
      running.whenComplete(() => finished = true);
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      final conflict = expectLater(
        ComicSourcePage.update(source, false),
        throwsA('Update already in progress'.tl),
      );
      // The first update fails with a network error, which is swallowed above.
      requests.items.single.reply('', status: 503);
      await _pumpUntil(tester, () => finished);
      await conflict;
      await running;
      await tester.pump();
      expect(find.text('Loading'), findsNothing);
    },
  );

  sourceScenario(
    'cancel repository lookup closes loading without starting a script download',
    (tester) async {
      await pumpPage(tester);
      final source = install(linked: true);
      final update = ComicSourcePage.update(source);
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      final lookup = requests.items.single;
      expect(lookup.options.uri.toString(), repository.url);
      await tester.tap(find.text('Cancel'));
      await _pumpUntil(tester, () => lookup.cancelled);
      await update;
      await tester.pump();
      expect(find.text('Loading'), findsNothing);
      lookup.reply(catalog());
      await tester.pump();
      expect(requests.items, hasLength(1));
      expect(ComicSourceManager().find(source.key), same(source));
      expect(File(source.filePath).readAsStringSync(), 'original content');
      expect(messages, isEmpty);
    },
  );

  sourceScenario(
    'failed update preserves the source, closes loading and permits retry',
    (tester) async {
      await pumpPage(tester);
      final source = install();
      final update = ComicSourcePage.update(source);
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      requests.items.single.reply('', status: 503);
      await _pumpUntil(tester, () => messages.isNotEmpty);
      await update;
      expect(messages, ['Network error']);
      expect(find.text('Loading'), findsNothing);
      expect(ComicSourceManager().find(source.key), same(source));
      expect(File(source.filePath).readAsStringSync(), 'original content');
      final retry = ComicSourcePage.update(source);
      await _pumpUntil(tester, () => requests.items.length == 2);
      await tester.tap(find.text('Cancel'));
      await _pumpUntil(tester, () => requests.items.last.cancelled);
      await retry;
    },
  );

  // The old single-list editor was replaced by repository management. Keep its
  // validate-before-save and URL binding guarantees against the new public API.
  sourceScenario(
    'save and edit validate first and persist the loaded catalog address',
    (tester) async {
      await pumpPage(tester);
      SourceRepository? saved;
      final save = SourceRepositories.instance
          .save(name: 'Repo', url: '  https://example.test/repo/index.json  ')
          .then((value) => saved = value);
      await _pumpUntil(tester, () => requests.items.length == 1);
      expect(SourceRepositories.instance.all, isEmpty);
      requests.items.single.reply(catalog());
      await _pumpUntil(tester, () => saved != null);
      await save;
      expect(saved!.url, repository.url);
      final persisted = jsonDecode(
        File('${dataDir.path}/appdata.json').readAsStringSync(),
      );
      expect(
        persisted['settings']['comicSourceRepositories'].single['url'],
        repository.url,
      );
      final edit = SourceRepositories.instance.save(
        id: saved!.id,
        name: 'New',
        url: 'https://new.test/index.json',
      );
      final failed = expectLater(edit, throwsA(isA<DioException>()));
      await _pumpUntil(tester, () => requests.items.length == 2);
      requests.items.last.reply('', status: 503);
      await _pumpUntil(tester, () => requests.closedClients >= 2);
      await failed;
      expect(SourceRepositories.instance.find(saved!.id)!.url, repository.url);
      final changed = SourceRepositories.instance.save(
        id: saved!.id,
        name: 'New',
        url: 'https://new.test/index.json',
      );
      await _pumpUntil(tester, () => requests.items.length == 3);
      requests.items.last.reply(catalog());
      var finished = false;
      final done = changed.then((_) => finished = true);
      await _pumpUntil(tester, () => finished);
      await done;
      expect(
        SourceRepositories.instance.find(saved!.id)!.url,
        'https://new.test/index.json',
      );
      expect(messages, isEmpty);
    },
  );

  sourceScenario(
    'closing catalog cancels the request and ignores its late response',
    (tester) async {
      await pumpPage(
        tester,
        child: const SourceRepositoryCatalogPage(repository: repository),
      );
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      final request = requests.items.single;
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(tester, () => request.cancelled);
      request.reply(catalog());
      await tester.pump();
      expect(messages, isEmpty);
      expect(requests.closedClients, 1);
      expect(tester.takeException(), isNull);
    },
  );

  sourceScenario('catalog HTTP failure clears loading and refresh can retry', (
    tester,
  ) async {
    await pumpPage(
      tester,
      child: const SourceRepositoryCatalogPage(repository: repository),
    );
    await _pumpUntil(tester, () => requests.items.isNotEmpty);
    requests.items.single.reply('', status: 503);
    await _pumpUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    expect(requests.closedClients, 1);
    await tester.tap(find.text('Refresh list'));
    await _pumpUntil(tester, () => requests.items.length == 2);
    requests.items.last.reply(catalog());
    await _pumpUntil(
      tester,
      () => find.text('Installed Source').evaluate().isNotEmpty,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'headless update propagates download errors without removing the source',
    () async {
      setUpScenario();
      addTearDown(tearDownScenario);
      final source = install();
      final result = expectLater(
        ComicSourcePage.update(source, false),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();
      requests.items.single.reply('', status: 503);
      await result;
      expect(ComicSourceManager().find(source.key), same(source));
      expect(File(source.filePath).readAsStringSync(), 'original content');
      expect(requests.closedClients, 1);
    },
  );

  testWidgets(
    'source update and repository cancellation regression scenarios',
    (tester) async {
      tester.view.physicalSize = const Size(480, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Keep Appdata's shared write queue within the same widget-test clock.
      for (final scenario in scenarios) {
        debugPrint('Source scenario: ${scenario.name}');
        setUpScenario();
        try {
          await scenario.body(tester);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          for (final request in requests.items) {
            if (!request.response.isCompleted) request.reply('', status: 503);
          }
          await tester.pump();
          await _flushSettings(tester);
          tearDownScenario();
        }
      }
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
    await tester.runAsync(() => pumpEventQueue());
  }
  fail('The expected asynchronous source operation did not complete.');
}

Future<void> _flushSettings(WidgetTester tester) async {
  var saved = false;
  final saving = appdata.saveData(false).then((_) => saved = true);
  await _pumpUntil(tester, () => saved);
  await saving;
}

class _PendingRequest {
  _PendingRequest(this.options, Future<void>? cancelFuture) {
    cancelFuture?.then((_) => cancelled = true);
  }

  final RequestOptions options;
  final response = Completer<ResponseBody>();
  bool cancelled = false;

  void reply(String body, {int status = 200}) {
    response.complete(ResponseBody.fromString(body, status));
  }
}

class _SourceRequests implements HttpClientAdapter {
  final items = <_PendingRequest>[];
  int closedClients = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final request = _PendingRequest(options, cancelFuture);
    items.add(request);
    return request.response.future;
  }

  @override
  void close({bool force = false}) {
    closedClients++;
  }
}

ComicSource _installedSource(String filePath) => ComicSource(
  'Installed Source',
  'installed_source',
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  filePath,
  'https://example.test/installed.js',
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
