import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:venera_next/app_runtime/headless_source_updates.dart';
import 'package:venera_next/app_runtime/headless_source_update_command.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source_installations_scope.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/routing/app_navigation.dart';

import '../../support/source_data_files.dart';

String script(
  String version, {
  String key = 'owned',
  String init = '',
  bool search = false,
}) =>
    '''
class Owned_$key extends ComicSource {
  key = '$key'; name = 'Owned $key'; version = '$version';
  minAppVersion = '1.0.0'; url = 'https://example.test/$key.js';
  comic = {loadInfo: () => ({title:'Book',cover:'',tags:{}}), loadEp: () => []};
  ${search ? 'search = {load: () => ({comics: []})};' : ''}
  async init() { $init }
}
''';

void main() {
  late Directory root;
  late JsEngine engine;
  late ComicSourceManager manager;
  late ComicSource source;
  late SourceInstallations queue;
  late SourceUpdateService service;
  late SelectionTaskRegistry tasks;
  late _Requests requests;
  late GlobalKey<NavigatorState> navigator;
  late bool allowed;
  late ControlledSourceDataFiles dataFiles;
  final messages = <String>[];
  final services = <SourceUpdateService>[];

  Future<void> prepare(WidgetTester tester) async {
    messages.clear();
    services.clear();
    allowed = true;
    tasks = SelectionTaskRegistry();
    navigator = GlobalKey<NavigatorState>();
    requests = _Requests();
    registerShowMessageHandler((_, message) => messages.add(message));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    await tester.runAsync(() async {
      if (Platform.isWindows) {
        final native = Directory('build/windows/x64/runner/Release').absolute;
        DynamicLibrary.open('${native.path}/flutter_windows.dll');
        DynamicLibrary.open('${native.path}/flutter_qjs_plugin.dll');
      }
      root = Directory.systemTemp.createTempSync('source-update-ownership-');
      Directory('${root.path}/comic_source').createSync();
      App.dataPath = root.path;
      App.cachePath = root.path;
      App.version = '9.0.0';
      App.isInitialized = false;
      Log.isMuted = true;
      rootBundle.clear();
      await appdata.init();
      await appdata.updateSettings((draft) {
        draft['language'] = 'en-US';
        draft['comicSourceRepositories'] = [
          {
            'id': 'repo',
            'name': 'Repo',
            'url': 'https://example.test/index.json',
          },
        ];
        draft['comicSourceOrigins'] = {
          'owned': {
            'kind': 'repository',
            'repositoryId': 'repo',
            'url': 'https://example.test/owned.js',
          },
        };
      }, sync: false);
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      engine = JsEngine();
      await engine.init();
      dataFiles = ControlledSourceDataFiles();
      final storage = SourceDataStorage(files: dataFiles);
      manager = ComicSourceManager(dataStorage: storage);
      final path = '${root.path}/comic_source/owned.js';
      File(path).writeAsStringSync(script('1.0.0'));
      source = await ComicSourceParser(
        dataStorage: storage,
      ).parse(script('1.0.0'), path);
      manager.add(source);
      service = SourceUpdateService(
        manager: manager,
        repositories: SourceRepositories.instance,
        createDio: () => Dio()..httpClientAdapter = requests,
      );
      services.add(service);
      queue = SourceInstallations(
        manager: manager,
        repositories: SourceRepositories.instance,
        createClient: Dio.new,
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      requests.release();
      await drain(tester, () async {
        dataFiles.beforeWrite = null;
        dataFiles.beforeReplace = null;
        configureComicSourceDataSavedHandler(null);
        for (final owner in services) {
          await owner.closeAndWait();
        }
        await tasks.closeAndWait();
        await queue.closeAndWait();
        await manager.closeAndWait();
        await engine.closeAndWait();
        await appdata.runPersistenceMaintenance((_) async {});
      });
      await tester.runAsync(() => root.delete(recursive: true));
      Log.isMuted = false;
      registerShowMessageHandler((_, _) {});
      appNavigation.registerForceRebuild(null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  }

  Future<void> show(
    WidgetTester tester, {
    bool globalNavigator = false,
    bool settle = true,
    bool window = false,
    VoidCallback? onExit,
    VoidCallback? refresh,
  }) async {
    if (globalNavigator) navigator = appNavigation.rootNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) {
          Widget content = NavigationAdmission(
            allowsNavigation: () => allowed,
            child: SelectionTasksScope(
              registry: tasks,
              child: SourceInstallationsScope(
                queue: queue,
                updates: service,
                refresh: refresh,
                child: child!,
              ),
            ),
          );
          if (window) content = WindowFrame(content, onExit: onExit);
          return content;
        },
        home: const ComicSourcePage(),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> startCheck(WidgetTester tester) async {
    await tester.tap(find.text('Check updates'));
    await pumpUntil(tester, () => requests.items.isNotEmpty);
  }

  PopupMenuButton<String> menu(WidgetTester tester) =>
      tester.widget<PopupMenuButton<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is PopupMenuButton<String> &&
              widget.tooltip == 'Source actions',
        ),
      );

  Future<ComicSource> addSource(WidgetTester tester, String key) async =>
      (await tester.runAsync<ComicSource>(() async {
        final path = '${root.path}/comic_source/$key.js';
        File(path).writeAsStringSync(script('1.0.0', key: key));
        final added = await ComicSourceParser(
          dataStorage: SourceDataStorage(files: dataFiles),
        ).parse(script('1.0.0', key: key), path);
        manager.add(added);
        await appdata.updateSettings((draft) {
          draft['comicSourceOrigins'] = {
            ...draft['comicSourceOrigins'] as Map,
            key: {
              'kind': 'repository',
              'repositoryId': 'repo',
              'url': 'https://example.test/$key.js',
            },
          };
        }, sync: false);
        return added;
      }))!;

  Future<SourceUpdateReport> check(
    WidgetTester tester, {
    List<String> keys = const ['owned'],
  }) async {
    final count = requests.items.length;
    final pending = service.checkUpdates();
    expect(identical(pending, service.checkUpdates()), isTrue);
    await pumpUntil(tester, () => requests.items.length > count);
    requests.items[count].replyCatalog('2.0.0', keys: keys);
    late SourceUpdateReport result;
    await drain(tester, () async {
      result = await pending;
    });
    return result;
  }

  Future<void> download(
    WidgetTester tester, {
    String key = 'owned',
    String init = '',
    bool search = false,
    List<String> keys = const ['owned'],
  }) async {
    final count = requests.items.length;
    await pumpUntil(tester, () => requests.items.length > count);
    requests.items[count].replyCatalog('2.0.0', keys: keys);
    await pumpUntil(tester, () => requests.items.length > count + 1);
    expect(requests.items[count + 1].options.uri.path, '/$key.js');
    requests.items[count + 1].reply(
      script('2.0.0', key: key, init: init, search: search),
    );
  }

  Future<void> showUpdates(
    WidgetTester tester, {
    List<String> keys = const ['owned'],
  }) async {
    await startCheck(tester);
    requests.items.last.replyCatalog('2.0.0', keys: keys);
    await pumpUntil(
      tester,
      () => find.text('Source update check').evaluate().isNotEmpty,
    );
    // The check button remains busy behind this non-opaque dialog.
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> confirmDelete(WidgetTester tester) async {
    menu(tester).onSelected!('delete');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<({Future<void> work, Completer<void> release})> holdSettings(
    WidgetTester tester,
  ) async {
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final work = appdata.runPersistenceMaintenance((_) async {
      entered.complete();
      await release.future;
    });
    await pumpUntil(tester, () => entered.isCompleted);
    return (work: work, release: release);
  }

  testWidgets('service replacement suppresses the old check result', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await startCheck(tester);
    final replacement = SourceUpdateService(createDio: Dio.new);
    services.add(replacement);
    service = replacement;
    await show(tester, settle: false);
    requests.items.single.replyCatalog('1.0.0');
    await pumpUntil(tester, () => requests.closed > 0);
    await tester.pumpAndSettle();
    expect(messages, isEmpty);
  });

  testWidgets('covered route ignores late check notices', (tester) async {
    await prepare(tester);
    await show(tester);
    await startCheck(tester);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    requests.items.single.replyCatalog('1.0.0');
    await pumpUntil(tester, () => requests.closed > 0);
    await tester.pumpAndSettle();
    expect(messages, isEmpty);
    expect(find.text('New page'), findsOneWidget);
  });

  testWidgets('original application waits for an accepted check', (
    tester,
  ) async {
    await prepare(tester);
    requests.holdIdle = true;
    await show(tester);
    await startCheck(tester);
    final checking = service.checkUpdates();
    var closed = false;
    final closing = tasks.closeAndWait().then((_) => closed = true);
    await tester.pump();
    final closedBeforeResponse = closed;
    requests.items.single.replyCatalog('1.0.0');
    await pumpUntil(tester, () => requests.closed > 0);
    final closedBeforeIdle = closed;
    requests.release();
    await drain(tester, () async {
      await checking;
      await closing;
    });
    expect(closedBeforeResponse, isFalse);
    expect(closedBeforeIdle, isFalse);
    expect(messages, isEmpty);
  });

  testWidgets('source delete uses the local navigator', (tester) async {
    await prepare(tester);
    await show(tester);
    menu(tester).onSelected!('delete');
    await tester.pumpAndSettle();
    expect(find.text('Uninstall source'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frozen delete callback cannot open confirmation', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester, globalNavigator: true);
    final selected = menu(tester).onSelected!;
    allowed = false;
    selected('delete');
    await tester.pumpAndSettle();
    expect(find.text('Uninstall source'), findsNothing);
  });

  testWidgets(
    'a check returns immutable results independent of registry summaries',
    (tester) async {
      await prepare(tester);
      final report = await check(tester);
      expect(report.sources['owned'], same(source));
      expect(report.updates, {'owned': '2.0.0'});
      expect(report.checked, 1);
      expect(() => report.updates.clear(), throwsUnsupportedError);
      expect(() => report.failures.clear(), throwsUnsupportedError);
      expect(() => report.sources.clear(), throwsUnsupportedError);
      manager.updateAvailableUpdates({'unrelated': '9.0.0'});
      expect(report.updates, {'owned': '2.0.0'});
      final updating = report.update('owned');
      await download(tester);
      await drain(tester, () => updating);
      expect(manager.find('owned')!.version, '2.0.0');
      expect(File(source.filePath).readAsStringSync(), script('2.0.0'));
    },
  );

  testWidgets('a check discards results when its original source is replaced', (
    tester,
  ) async {
    await prepare(tester);
    final pending = service.checkUpdates();
    await pumpUntil(tester, () => requests.items.isNotEmpty);
    await tester.runAsync(
      () => manager.replaceScript(source, script('8.0.0'), validate: () {}),
    );
    requests.items.single.replyCatalog('9.0.0');
    late SourceUpdateReport result;
    await drain(tester, () async {
      result = await pending;
    });
    expect(result.updates, isEmpty);
    expect(result.failures.single.cause, _changed);
    expect(manager.availableUpdates, isEmpty);
    expect(manager.find('owned')!.version, '8.0.0');
  });

  for (final change in ['source', 'origin', 'repository', 'directory']) {
    testWidgets(
      'a report rejects changed $change before starting a new client',
      (tester) async {
        await prepare(tester);
        final report = await check(tester);
        final count = requests.items.length;
        switch (change) {
          case 'source':
            await tester.runAsync(
              () => manager.replaceScript(
                source,
                script('8.0.0'),
                validate: () {},
              ),
            );
          case 'origin':
            appdata.settings['comicSourceOrigins'] = {
              'owned': {
                'kind': 'repository',
                'repositoryId': 'repo',
                'url': 'https://example.test/changed.js',
              },
            };
          case 'repository':
            appdata.settings['comicSourceRepositories'] = [
              {
                'id': 'repo',
                'name': 'Repo',
                'url': 'https://elsewhere.test/index.json',
              },
            ];
          case 'directory':
            App.dataPath = (Directory('${root.path}/other')..createSync()).path;
        }
        try {
          await expectLater(report.update('owned'), throwsA(_changed));
          expect(requests.items, hasLength(count));
          expect(
            File(source.filePath).readAsStringSync(),
            script(change == 'source' ? '8.0.0' : '1.0.0'),
          );
        } finally {
          App.dataPath = root.path;
        }
      },
    );
  }

  testWidgets('an old request cancellation cannot cancel its immediate retry', (
    tester,
  ) async {
    await prepare(tester);
    requests.holdIdle = true;
    final oldToken = CancelToken(), newToken = CancelToken();
    final old = expectLater(
      service.update(source, cancelToken: oldToken),
      throwsA(_cancelled),
    );
    await pumpUntil(tester, () => requests.items.length == 1);
    service.cancel(source.key, request: oldToken);
    final current = expectLater(
      service.update(source, cancelToken: newToken),
      throwsA(_cancelled),
    );
    await pumpUntil(tester, () => requests.items.length == 2);
    service.cancel(source.key, request: oldToken);
    expect(newToken.isCancelled, isFalse);
    expect(service.isUpdating(source.key), isTrue);
    requests.items.first.replyCatalog('9.0.0');
    await tester.pump(const Duration(milliseconds: 20));
    expect(service.isUpdating(source.key), isTrue);
    service.cancel(source.key, request: newToken);
    requests.release();
    await drain(tester, () async {
      await old;
      await current;
    });
    expect(manager.find('owned'), same(source));
  });

  testWidgets('cancellation retains client cleanup failures and their cause', (
    tester,
  ) async {
    await prepare(tester);
    final closeError = StateError('owned client close failed');
    requests.closeError = closeError;
    final token = CancelToken();
    final pending = service.update(source, cancelToken: token);
    final observed = expectLater(
      pending,
      throwsA(
        isA<SourceUpdateCloseFailure>()
            .having(
              (error) => error.cause,
              'cancelled request',
              isA<DioException>(),
            )
            .having(
              (error) => error.failures.single.error,
              'cleanup',
              same(closeError),
            ),
      ),
    );
    await pumpUntil(tester, () => requests.items.isNotEmpty);
    service.cancel(source.key, request: token);
    await drain(tester, () => observed);
    await expectLater(
      service.closeAndWait(),
      throwsA(isA<SourceUpdateCloseFailure>()),
    );
    // The fake adapter has no native resources; the cached failure was checked.
    services.remove(service);
  });

  testWidgets(
    'cancelling after mutation admission preserves an applied failure',
    (tester) async {
      await prepare(tester);
      final failure = StateError('publication failed after source commit');
      configureComicSourceDataSavedHandler(() async => throw failure);
      final token = CancelToken();
      SourceMutationFailure? received;
      final pending = service
          .update(
            source,
            cancelToken: token,
            onCommit: () => service.cancel(source.key, request: token),
          )
          .then<void>(
            (_) => fail('Expected the publication failure'),
            onError: (Object error, StackTrace stack) {
              expectSync(error, isA<SourceMutationFailure>());
              received = error as SourceMutationFailure;
              expectSync(stack.toString(), isNotEmpty);
            },
          );
      await download(
        tester,
        init: 'globalThis.updateRuns = (globalThis.updateRuns || 0) + 1;',
      );
      await drain(tester, () => pending);
      configureComicSourceDataSavedHandler(null);
      expect(received!.state, SourceMutationState.applied);
      expect((received!.cause as SourceMutationFailure).cause, same(failure));
      expect(Directory(received!.recoveryPath!).existsSync(), isTrue);
      expect(manager.find('owned')!.version, '2.0.0');
      expect(engine.runCode('updateRuns'), 1);
    },
  );

  testWidgets(
    'cancelling after mutation admission preserves incomplete recovery',
    (tester) async {
      await prepare(tester);
      dataFiles.beforeReplace = (_, _) =>
          throw const FileSystemException('source data denied');
      var changed = false;
      void changeScript() {
        if (!changed &&
            (appdata.settings['searchSources'] as List).contains('owned')) {
          changed = true;
          File(source.filePath).writeAsStringSync('// independent edit');
        }
      }

      appdata.settings.addListener(changeScript);
      final token = CancelToken();
      SourceMutationFailure? received;
      final pending = service
          .update(
            source,
            cancelToken: token,
            onCommit: () => service.cancel(source.key, request: token),
          )
          .then<void>(
            (_) => fail('Expected incomplete recovery'),
            onError: (Object error, StackTrace stack) {
              expectSync(error, isA<SourceMutationFailure>());
              received = error as SourceMutationFailure;
            },
          );
      try {
        await download(tester, search: true);
        await drain(tester, () => pending);
      } finally {
        appdata.settings.removeListener(changeScript);
        dataFiles.beforeReplace = null;
      }
      expect(received!.state, SourceMutationState.recoveryRequired);
      expect(
        received!.failures.map((e) => e.stage),
        contains('restore source script'),
      );
      expect(File(source.filePath).readAsStringSync(), '// independent edit');
      expect(manager.find('owned'), same(source));
    },
  );

  testWidgets(
    'closing unused or old services never creates a replacement manager',
    (tester) async {
      await prepare(tester);
      final report = await check(tester);
      await drain(tester, manager.closeAndWait);
      expect(ComicSourceManager.current, isNull);
      final unused = SourceUpdateService();
      await unused.closeAndWait();
      await expectLater(report.update('owned'), throwsStateError);
      expect(ComicSourceManager.current, isNull);
      expect(requests.items, hasLength(1));
    },
  );

  testWidgets('CLI retains the checked target after mutable summaries change', (
    tester,
  ) async {
    await prepare(tester);
    final pending = checkSourceUpdatesForCli(service);
    await pumpUntil(tester, () => requests.items.isNotEmpty);
    requests.items.single.replyCatalog('2.0.0');
    late HeadlessSourceUpdateCheck report;
    await drain(tester, () async {
      report = await pending;
    });
    manager.updateAvailableUpdates({});
    await tester.runAsync(
      () => manager.replaceScript(source, script('8.0.0'), validate: () {}),
    );
    expect(report.updates.single.version, '1.0.0');
    final output = <Map<String, dynamic>>[];
    final exitCode = await runHeadlessSourceUpdateCommand(
      checkUpdates: () async => report,
      emit: output.add,
    );
    expect(exitCode, 1);
    expect(output.last['data'], {'total': 1, 'updated': 0, 'errors': 1});
    expect((output[2]['data'] as Map)['source'], {
      'key': 'owned',
      'name': 'Owned owned',
      'version': '1.0.0',
      'url': 'https://example.test/owned.js',
    });
    expect(manager.find('owned')!.version, '8.0.0');
    expect(requests.items, hasLength(1));
  });

  testWidgets(
    'the original window waits for the shared check and native idle',
    (tester) async {
      await prepare(tester);
      requests.holdIdle = true;
      var exits = 0;
      await show(tester, window: true, onExit: () => exits++);
      await startCheck(tester);
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump(const Duration(milliseconds: 20));
      expect(exits, 0);
      requests.items.single.replyCatalog('1.0.0');
      await pumpUntil(tester, () => requests.closed > 0);
      expect(exits, 0);
      requests.release();
      await pumpUntil(tester, () => exits == 1);
      expect(messages, isEmpty);
    },
  );

  testWidgets('a covered update confirmation never pops the covering route', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await showUpdates(tester);
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Update'))
        .onPressed!;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();
    expect(find.text('Covering page'), findsOneWidget);
    expect(requests.items, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await drain(tester, tasks.closeAndWait);
    expect(manager.find('owned'), same(source));
  });

  testWidgets('frozen retained update callbacks cannot start network work', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    final selected = menu(tester).onSelected!;
    final checkButton = tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Check updates'),
        )
        .onPressed!;
    allowed = false;
    selected('update');
    checkButton();
    await tester.pumpAndSettle();
    expect(requests.items, isEmpty);
    expect(find.text('Loading'), findsNothing);
  });

  testWidgets(
    'batch updates both original sources despite its own repository revision change',
    (tester) async {
      await prepare(tester);
      final second = await addSource(tester, 'second');
      var refreshed = 0;
      await show(tester, refresh: () => refreshed++);
      await showUpdates(tester, keys: ['owned', 'second']);
      final revision = SourceRepositories.instance.revision;
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await download(tester, keys: ['owned', 'second']);
      await download(tester, key: 'second', keys: ['owned', 'second']);
      await pumpUntil(tester, () => refreshed == 2);
      await tester.pumpAndSettle();
      expect(SourceRepositories.instance.revision, greaterThan(revision));
      expect(manager.find('owned')!.version, '2.0.0');
      expect(manager.find('second')!.version, '2.0.0');
      expect(File(source.filePath).readAsStringSync(), script('2.0.0'));
      expect(
        File(second.filePath).readAsStringSync(),
        script('2.0.0', key: 'second'),
      );
      expect(requests.items, hasLength(5));
      expect(messages, isEmpty);
    },
  );

  testWidgets(
    'batch cancellation stops current download and does not start the next source',
    (tester) async {
      await prepare(tester);
      final second = await addSource(tester, 'second');
      await show(tester);
      await showUpdates(tester, keys: ['owned', 'second']);
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await pumpUntil(tester, () => requests.items.length == 2);
      await tester.tap(find.text('Cancel'));
      await pumpUntil(tester, () => requests.items.last.cancelled);
      requests.items.last.replyCatalog('9.0.0', keys: ['owned', 'second']);
      await drain(tester, tasks.closeAndWait);
      expect(requests.items, hasLength(2));
      expect(manager.find('owned'), same(source));
      expect(manager.find('second'), same(second));
    },
  );

  testWidgets(
    'batch cancellation drains an admitted mutation without starting the next one',
    (tester) async {
      await prepare(tester);
      final second = await addSource(tester, 'second');
      await show(tester);
      await showUpdates(tester, keys: ['owned', 'second']);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      dataFiles.beforeReplace = (_, _) async {
        entered.complete();
        await release.future;
      };
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await download(tester, keys: ['owned', 'second']);
      await pumpUntil(tester, () => entered.isCompleted);
      await tester.tap(find.text('Cancel'));
      var closed = false;
      final closing = tasks.closeAndWait().then((_) => closed = true);
      await tester.pump(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      dataFiles.beforeReplace = null;
      release.complete();
      await drain(tester, () => closing);
      expect(manager.find('owned')!.version, '2.0.0');
      expect(File(source.filePath).readAsStringSync(), script('2.0.0'));
      expect(manager.find('second'), same(second));
      expect(requests.items, hasLength(3));
      expect(messages, isEmpty);
    },
  );

  testWidgets('batch continues after an ordinary network failure', (
    tester,
  ) async {
    await prepare(tester);
    final second = await addSource(tester, 'second');
    await show(tester);
    await showUpdates(tester, keys: ['owned', 'second']);
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await pumpUntil(tester, () => requests.items.length == 2);
    requests.items.last.replyCatalog('2.0.0', keys: ['owned', 'second']);
    await pumpUntil(tester, () => requests.items.length == 3);
    requests.items.last.reply('', status: 503);
    await download(tester, key: 'second', keys: ['owned', 'second']);
    await pumpUntil(tester, () => messages.isNotEmpty);
    expect(manager.find('owned'), same(source));
    expect(manager.find('second')!.version, '2.0.0');
    expect(
      File(second.filePath).readAsStringSync(),
      script('2.0.0', key: 'second'),
    );
    expect(messages.single, contains('Owned owned:'));
    expect(requests.items, hasLength(5));
  });

  testWidgets('batch stops after an applied mutation failure', (tester) async {
    await prepare(tester);
    final second = await addSource(tester, 'second');
    await show(tester);
    await showUpdates(tester, keys: ['owned', 'second']);
    configureComicSourceDataSavedHandler(
      () async => throw StateError('batch publication failed'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await download(tester, keys: ['owned', 'second']);
    await pumpUntil(tester, () => messages.isNotEmpty);
    configureComicSourceDataSavedHandler(null);
    expect(messages.single, contains('Source change was applied'));
    expect(manager.find('owned')!.version, '2.0.0');
    expect(manager.find('second'), same(second));
    expect(requests.items, hasLength(3));
  });

  testWidgets('delete confirmation is unique and tied to its current route', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    final selected = menu(tester).onSelected!;
    selected('delete');
    selected('delete');
    await tester.pumpAndSettle();
    expect(find.text('Uninstall source'), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
        .onPressed!;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering deletion')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();
    expect(find.text('Covering deletion'), findsOneWidget);
    expect(manager.find('owned'), same(source));
    await tester.pumpWidget(const SizedBox());
    await drain(tester, tasks.closeAndWait);
    expect(File(source.filePath).existsSync(), isTrue);
  });

  testWidgets(
    'delete refresh belongs to the original page rather than a later global callback',
    (tester) async {
      await prepare(tester);
      var original = 0, replacement = 0;
      await show(tester, refresh: () => original++);
      final hold = await holdSettings(tester);
      await confirmDelete(tester);
      await pumpUntil(
        tester,
        () => File(
          '${root.path}/.source-transactions/transactions.sqlite',
        ).existsSync(),
      );
      appNavigation.registerForceRebuild(() => replacement++);
      hold.release.complete();
      await drain(tester, () => hold.work);
      await pumpUntil(tester, () => original == 1);
      expect(replacement, 0);
      expect(manager.find('owned'), isNull);
      expect(File(source.filePath).existsSync(), isFalse);
    },
  );

  for (final window in [false, true]) {
    testWidgets(
      'the original ${window ? 'window' : 'application'} waits for an accepted deletion',
      (tester) async {
        await prepare(tester);
        var exits = 0, refreshes = 0;
        await show(
          tester,
          window: window,
          onExit: () => exits++,
          refresh: () => refreshes++,
        );
        final hold = await holdSettings(tester);
        await confirmDelete(tester);
        await pumpUntil(
          tester,
          () => File(
            '${root.path}/.source-transactions/transactions.sqlite',
          ).existsSync(),
        );
        var closed = false;
        Future<void>? closing;
        if (window) {
          (tester.state(find.byType(WindowFrame)) as WindowListener)
              .onWindowClose();
        } else {
          closing = tasks.closeAndWait().then((_) => closed = true);
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pump(const Duration(milliseconds: 20));
        expect(exits, 0);
        expect(closed, isFalse);
        hold.release.complete();
        await drain(tester, () => hold.work);
        await pumpUntil(tester, () => window ? exits == 1 : closed);
        if (closing != null) await closing;
        expect(manager.find('owned'), isNull);
        expect(File(source.filePath).existsSync(), isFalse);
        expect(refreshes, 0);
        expect(messages, isEmpty);
      },
    );
  }

  testWidgets(
    'queued deletion validates its original directory before mutation',
    (tester) async {
      await prepare(tester);
      await show(tester);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final held = AppDataOperations.instance.prepare(() async {
        entered.complete();
        await release.future;
      });
      await pumpUntil(tester, () => entered.isCompleted);
      await confirmDelete(tester);
      final other = Directory('${root.path}/other')..createSync();
      App.dataPath = other.path;
      release.complete();
      try {
        await drain(tester, () async {
          await held;
          await tasks.closeAndWait();
        });
        expect(manager.find('owned'), same(source));
        expect(File(source.filePath).readAsStringSync(), script('1.0.0'));
        expect(
          Directory('${other.path}/.source-transactions').existsSync(),
          isFalse,
        );
      } finally {
        App.dataPath = root.path;
      }
    },
  );

  testWidgets(
    'incomplete deletion recovery blocks replay through a retained action',
    (tester) async {
      await prepare(tester);
      await show(tester);
      final selected = menu(tester).onSelected!;
      var changed = false;
      void changeScript() {
        if (!changed &&
            SourceRepositories.instance.originFor('owned') == null) {
          changed = true;
          File(source.filePath).writeAsStringSync('// external deletion edit');
        }
      }

      appdata.settings.addListener(changeScript);
      try {
        await confirmDelete(tester);
        await pumpUntil(tester, () => messages.isNotEmpty);
      } finally {
        appdata.settings.removeListener(changeScript);
      }
      expect(messages.single, contains('Source recovery is incomplete'));
      expect(manager.find('owned'), same(source));
      expect(
        File(source.filePath).readAsStringSync(),
        '// external deletion edit',
      );
      selected('delete');
      await tester.pumpAndSettle();
      expect(find.text('Uninstall source'), findsNothing);
      expect(messages, hasLength(2));
      expect(messages.last, messages.first);
    },
  );
}

class _Request {
  _Request(this.options, Future<void>? cancellation) {
    cancellation?.then((_) => cancelled = true);
  }
  final RequestOptions options;
  final response = Completer<ResponseBody>();
  bool cancelled = false;
  void reply(String body, {int status = 200}) {
    response.complete(ResponseBody.fromString(body, status));
  }

  void replyCatalog(String version, {List<String> keys = const ['owned']}) =>
      reply(
        jsonEncode([
          for (final key in keys)
            {
              'key': key,
              'name': 'Owned $key',
              'version': version,
              'fileName': '$key.js',
            },
        ]),
      );
}

class _Requests extends RHttpAdapter {
  final items = <_Request>[];
  final _idle = Completer<void>();
  bool holdIdle = false;
  int closed = 0;
  Object? closeError;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final request = _Request(options, cancelFuture);
    items.add(request);
    return request.response.future;
  }

  @override
  void close({bool force = false}) {
    closed++;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<void> waitForIdle() => holdIdle ? _idle.future : Future<void>.value();
  void release() {
    if (!_idle.isCompleted) _idle.complete();
    for (final request in items) {
      if (!request.response.isCompleted) request.reply('', status: 503);
    }
  }
}

final _changed = isA<SourceFailure>().having(
  (error) => error.code,
  'code',
  SourceFailureCode.repositoryChanged,
);
final _cancelled = isA<SourceFailure>().having(
  (error) => error.code,
  'code',
  SourceFailureCode.cancelled,
);

Future<void> drain(WidgetTester tester, Future<void> Function() action) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final result = action().then<void>(
    (_) => done = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      done = true;
    },
  );
  await pumpUntil(tester, () => done);
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    // Drive Dio's queued request/response callbacks as well as real file I/O.
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Source update operation did not settle.');
}
