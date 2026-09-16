import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  late Directory dataDir;
  late _SourceRequests requests;
  late List<String> messages;
  late Object? previousListUrl;
  late bool previousLogMuted;
  final scenarios = <({String name, WidgetTesterCallback body})>[];

  void sourceScenario(String name, WidgetTesterCallback body) {
    scenarios.add((name: name, body: body));
  }

  void setUpScenario() {
    dataDir = Directory.systemTemp.createTempSync('venera-source-list-');
    Directory('${dataDir.path}/comic_source').createSync();
    App.dataPath = dataDir.path;
    previousListUrl = appdata.settings['comicSourceListUrl'];
    appdata.settings['comicSourceListUrl'] = '';
    previousLogMuted = Log.isMuted;
    Log.isMuted = true;
    requests = _SourceRequests();
    messages = [];
    ComicSourcePage.debugCreateDio = () =>
        AppDio()..httpClientAdapter = requests;
    registerShowMessageHandler((context, message) => messages.add(message));
  }

  void tearDownScenario() {
    ComicSourceManager().remove('installed_source');
    appdata.settings['comicSourceListUrl'] = previousListUrl;
    ComicSourcePage.debugCreateDio = null;
    registerShowMessageHandler((context, message) {});
    Log.isMuted = previousLogMuted;
    dataDir.deleteSync(recursive: true);
  }

  Future<void> pumpPage(WidgetTester tester, {bool sourcePage = true}) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: sourcePage ? const ComicSourcePage() : const Scaffold(),
      ),
    );
  }

  Future<void> openList(WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Comic Source list'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<_PendingRequest> refresh(WidgetTester tester, String url) async {
    final count = requests.items.length;
    await tester.enterText(find.byType(TextField).last, url);
    await tester.tap(find.text('Refresh'));
    await _pumpUntil(tester, () => requests.items.length == count + 1);
    return requests.items.last;
  }

  Future<void> loadList(
    WidgetTester tester, {
    String url = 'https://example.test/repo/index.json',
    Map<String, dynamic>? entry,
  }) async {
    final request = await refresh(tester, url);
    request.reply(_listJson(entry: entry));
    await _pumpUntil(
      tester,
      () => find.text('Example Source').evaluate().isNotEmpty,
    );
    await _flushSettings(tester);
  }

  Future<_PendingRequest> add(WidgetTester tester) async {
    final count = requests.items.length;
    await tester.tap(find.text('Add'));
    await _pumpUntil(tester, () => requests.items.length == count + 1);
    return requests.items.last;
  }

  Future<void> failDownload(
    WidgetTester tester,
    _PendingRequest request,
  ) async {
    request.reply('', status: 503);
    await _pumpUntil(tester, () => messages.isNotEmpty);
    expect(find.text('Loading'), findsNothing);
    expect(messages.last, 'Network error');
    expect(tester.takeException(), isNull);
  }

  sourceScenario(
    'first refresh saves its URL and immediately adds from that repo',
    (tester) async {
      await openList(tester);
      await loadList(tester, url: '  https://example.test/repo/index.json  ');

      expect(
        appdata.settings['comicSourceListUrl'],
        'https://example.test/repo/index.json',
      );
      final saved = jsonDecode(
        File('${dataDir.path}/appdata.json').readAsStringSync(),
      );
      expect(
        saved['settings']['comicSourceListUrl'],
        'https://example.test/repo/index.json',
      );

      final request = await add(tester);
      expect(
        request.options.uri.toString(),
        'https://example.test/repo/example.js',
      );
      expect(find.text('Loading'), findsOneWidget);
      await failDownload(tester, request);
      expect(find.text('Example Source'), findsOneWidget);
    },
  );

  sourceScenario('editing the input does not change the loaded list base URL', (
    tester,
  ) async {
    await openList(tester);
    await loadList(tester);
    await tester.enterText(
      find.byType(TextField).last,
      'https://other.test/index.json',
    );

    final request = await add(tester);
    expect(
      request.options.uri.toString(),
      'https://example.test/repo/example.js',
    );
    await failDownload(tester, request);

    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      appdata.settings['comicSourceListUrl'],
      'https://example.test/repo/index.json',
    );
  });

  sourceScenario(
    'switching repositories uses the new successfully loaded URL',
    (tester) async {
      appdata.settings['comicSourceListUrl'] = 'https://old.test/index.json';
      await openList(tester);
      await _pumpUntil(tester, () => requests.items.isNotEmpty);
      requests.items.single.reply(_listJson());
      await _pumpUntil(
        tester,
        () => find.text('Example Source').evaluate().isNotEmpty,
      );
      await loadList(tester, url: 'https://new.test/config/index.json');

      final request = await add(tester);
      expect(
        request.options.uri.toString(),
        'https://new.test/config/example.js',
      );
      await failDownload(tester, request);
    },
  );

  for (final staleFails in [false, true]) {
    sourceScenario('latest refresh wins when stale request fails=$staleFails', (
      tester,
    ) async {
      await openList(tester);
      final old = await refresh(tester, 'https://old.test/index.json');
      final current = await refresh(tester, 'https://new.test/index.json');
      current.reply(_listJson());
      await _pumpUntil(
        tester,
        () => find.text('Example Source').evaluate().isNotEmpty,
      );
      old.reply(
        _listJson(name: 'Stale Source'),
        status: staleFails ? 503 : 200,
      );
      await tester.pump();

      expect(old.cancelled, isTrue);
      expect(find.text('Stale Source'), findsNothing);
      expect(find.text('Example Source'), findsOneWidget);
      expect(
        appdata.settings['comicSourceListUrl'],
        'https://new.test/index.json',
      );
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  sourceScenario('failed refresh does not save over the last working repo', (
    tester,
  ) async {
    await openList(tester);
    await loadList(tester);
    final failed = await refresh(tester, 'https://offline.test/index.json');
    failed.reply('', status: 503);
    await _pumpUntil(tester, () => messages.isNotEmpty);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      appdata.settings['comicSourceListUrl'],
      'https://example.test/repo/index.json',
    );
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      appdata.settings['comicSourceListUrl'],
      'https://example.test/repo/index.json',
    );
  });

  sourceScenario(
    'closing a loading list cancels it without saving or reporting errors',
    (tester) async {
      await openList(tester);
      final request = await refresh(tester, 'https://example.test/index.json');
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      request.reply(_listJson());
      await tester.pump();

      expect(request.cancelled, isTrue);
      expect(appdata.settings['comicSourceListUrl'], isEmpty);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  sourceScenario('refreshing an empty input explicitly clears the saved repo', (
    tester,
  ) async {
    await openList(tester);
    await loadList(tester);
    await tester.enterText(find.byType(TextField).last, '   ');
    await tester.tap(find.text('Refresh'));
    await _flushSettings(tester);
    await tester.pumpAndSettle();

    expect(appdata.settings['comicSourceListUrl'], isEmpty);
    expect(requests.items, hasLength(1));
    expect(find.text('Example Source'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  for (final invalid in [
    'not json',
    '{}',
    '[null]',
    '[{"name": 42, "key": "bad"}]',
  ]) {
    sourceScenario(
      'rejects malformed list $invalid without saving its address',
      (tester) async {
        await openList(tester);
        final request = await refresh(
          tester,
          'https://example.test/index.json',
        );
        request.reply(invalid);
        await _pumpUntil(tester, () => messages.isNotEmpty);

        expect(messages.single, 'Invalid comic source list');
        expect(appdata.settings['comicSourceListUrl'], isEmpty);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  final urlCases =
      <
        ({
          String label,
          String base,
          Map<String, dynamic> entry,
          String expected,
        })
      >[
        (
          label: 'absolute url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': 'https://cdn.test/custom.js'},
          expected: 'https://cdn.test/custom.js',
        ),
        (
          label: 'relative url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': '../scripts/custom.js'},
          expected: 'https://example.test/scripts/custom.js',
        ),
        (
          label: 'root relative path',
          base: 'https://example.test/repo/index.json',
          entry: {'fileName': '/scripts/custom.js'},
          expected: 'https://example.test/scripts/custom.js',
        ),
        (
          label: 'query with slash',
          base: 'https://example.test/repo/index.json?token=a/b',
          entry: {'fileName': 'nested/custom.js'},
          expected: 'https://example.test/repo/nested/custom.js',
        ),
        (
          label: 'scheme relative url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': '//cdn.test/custom.js'},
          expected: 'https://cdn.test/custom.js',
        ),
        (
          label: 'local host and port',
          base: 'http://localhost:8080/index.json',
          entry: {'fileName': 'custom.js'},
          expected: 'http://localhost:8080/custom.js',
        ),
      ];
  for (final sample in urlCases) {
    sourceScenario('resolves ${sample.label} using URI semantics', (
      tester,
    ) async {
      await openList(tester);
      await loadList(tester, url: sample.base, entry: sample.entry);
      final request = await add(tester);
      expect(request.options.uri.toString(), sample.expected);
      await failDownload(tester, request);
    });
  }

  sourceScenario(
    'invalid source download URL reports an error without opening loading',
    (tester) async {
      await openList(tester);
      await loadList(tester, entry: {'url': 'file:///tmp/example.js'});
      await tester.tap(find.text('Add'));
      await tester.pump();

      expect(requests.items, hasLength(1));
      expect(messages.single, 'Invalid url config');
      expect(find.text('Loading'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  sourceScenario(
    'successful download closes loading before reporting a parse failure',
    (tester) async {
      await openList(tester);
      await loadList(
        tester,
        entry: {'url': 'https://cdn.test/custom.js?token=a/b#fragment'},
      );
      final request = await add(tester);
      request.reply('This is deliberately not a JavaScript source.');
      await _pumpUntil(tester, () => messages.isNotEmpty);

      expect(messages.single, 'Invalid Content');
      expect(find.text('Loading'), findsNothing);
      expect(Directory('${dataDir.path}/comic_source').listSync(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  sourceScenario(
    'cancelling a download ignores its late response and allows retry',
    (tester) async {
      await openList(tester);
      await loadList(tester);
      final request = await add(tester);
      await tester.tap(find.text('Cancel'));
      await _pumpUntil(tester, () => request.cancelled);
      request.reply('This cancelled source must not be parsed.');
      await tester.pump();

      expect(find.text('Loading'), findsNothing);
      expect(messages, isEmpty);
      expect(Directory('${dataDir.path}/comic_source').listSync(), isEmpty);
      final retry = await add(tester);
      await failDownload(tester, retry);
    },
  );

  sourceScenario('disposing the source page cancels its pending download', (
    tester,
  ) async {
    await openList(tester);
    await loadList(tester);
    final request = await add(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    request.reply('This disposed source must not be parsed.');
    await tester.pump();

    expect(request.cancelled, isTrue);
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [false, true]) {
    sourceScenario(
      'failed/cancelled update preserves installed source: cancel=$cancel',
      (tester) async {
        await pumpPage(tester, sourcePage: false);
        final source = _installedSource(
          '${dataDir.path}/comic_source/installed.js',
        );
        final manager = ComicSourceManager();
        manager.add(source);
        File(source.filePath).writeAsStringSync('original content');

        final update = ComicSourcePage.update(source);
        await _pumpUntil(tester, () => requests.items.isNotEmpty);
        final request = requests.items.single;
        expect(manager.find(source.key), same(source));
        if (cancel) {
          await tester.tap(find.text('Cancel'));
          await _pumpUntil(tester, () => request.cancelled);
          request.reply('cancelled update');
        } else {
          await failDownload(tester, request);
        }
        await update;
        await tester.pump();

        expect(find.text('Loading'), findsNothing);
        expect(manager.find(source.key), same(source));
        expect(File(source.filePath).readAsStringSync(), 'original content');
        expect(messages, cancel ? isEmpty : ['Network error']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'headless update propagates download errors without removing the source',
    () async {
      setUpScenario();
      addTearDown(tearDownScenario);
      final source = _installedSource(
        '${dataDir.path}/comic_source/installed.js',
      );
      final manager = ComicSourceManager();
      manager.add(source);
      final result = expectLater(
        ComicSourcePage.update(source, false),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();
      requests.items.single.reply('', status: 503);
      await result;
      expect(manager.find(source.key), same(source));
    },
  );

  testWidgets('source repository and download regression scenarios', (
    tester,
  ) async {
    // Appdata's shared write queue must stay within one widget-test clock.
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
  });
}

String _listJson({
  String name = 'Example Source',
  Map<String, dynamic>? entry,
}) => jsonEncode([
  {
    'name': name,
    'key': 'example_source',
    'version': '1.0.0',
    'fileName': 'example.js',
    ...?entry,
  },
]);

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
  void close({bool force = false}) {}
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
