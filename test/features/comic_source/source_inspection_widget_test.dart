import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_import_dialog.dart';
import 'package:venera_next/features/comic_source/source_installations_scope.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_repository_page.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:window_manager/window_manager.dart';

import '../../support/application_update_adapter.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

class _Harness {
  SelectionTaskRegistry? registry;
  bool window = true;
  final adapters = <ApplicationUpdateAdapter>[];
  final queue = SourceInstallations(
    manager: _PreviewManager(),
    repositories: SourceRepositories.instance,
    createClient: Dio.new,
  );
  final navigator = GlobalKey<NavigatorState>();
  int exits = 0;
  Dio createClient() {
    final adapter = ApplicationUpdateAdapter();
    adapters.add(adapter);
    return Dio()..httpClientAdapter = adapter;
  }

  Widget app(Widget child) => MaterialApp(
    navigatorKey: navigator,
    builder: (_, child) {
      final body = SourceInstallationsScope(
        queue: queue,
        child: window ? WindowFrame(child!, onExit: () => exits++) : child!,
      );
      return registry == null
          ? body
          : SelectionTasksScope(registry: registry!, child: body);
    },
    home: Scaffold(body: child),
  );
  void close(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
}

void main() {
  void inspectionTest(
    String name,
    Future<void> Function(WidgetTester, _Harness) body,
  ) {
    testWidgets(name, (tester) async {
      final fixture = _Harness();
      final language = appdata.settings['language'];
      final muted = Log.isMuted;
      appdata.settings['language'] = 'en-US';
      Log.isMuted = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => false,
      );
      try {
        await body(tester, fixture);
      } finally {
        for (final adapter in fixture.adapters) {
          if (!adapter.released.isCompleted) adapter.released.complete();
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await fixture.queue.closeAndWait();
        appdata.settings['language'] = language;
        Log.isMuted = muted;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        );
      }
    });
  }

  const first = SourceRepository(
    id: 'a',
    name: 'First',
    url: 'https://example.test/first.json',
  );
  const second = SourceRepository(
    id: 'b',
    name: 'Second',
    url: 'https://example.test/second.json',
  );

  inspectionTest(
    'invalid file preview retains parse cause on no-window host after page removal',
    (tester, fixture) async {
      final registry = SelectionTaskRegistry();
      fixture.registry = registry;
      fixture.window = false;
      final file = _File()..releaseError = StateError('file release');
      file.contents.complete(Uint8List.fromList('{'.codeUnits));
      await tester.pumpWidget(
        fixture.app(SourceImportDialog(pickFile: () async => file)),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await tester.pumpAndSettle();
      expect(file.reads, 1);
      expect(file.releases, 1);
      await tester.pumpWidget(fixture.app(const Text('Removed')));
      SelectionCleanupFailure? failure;
      try {
        await registry.closeAndWait();
      } on SelectionCleanupFailure catch (error) {
        failure = error;
      }
      final retained =
          (failure!.failures.single as ({Object error, StackTrace stack})).error
              as FileSelectionCleanupFailure;
      expect(
        retained.operationError,
        isA<SourceFailure>().having(
          (e) => e.cause,
          'JSON origin',
          isA<FormatException>(),
        ),
      );
      expect(retained.operationStack, isNotNull);
      file.releaseError = null;
      await registry.closeAndWait();
      expect(file.reads, 1);
      expect(fixture.queue.tasks, isEmpty);
    },
  );

  inspectionTest(
    'client factory reentry cannot let the window exit before native cleanup',
    (tester, fixture) async {
      await tester.pumpWidget(
        fixture.app(
          SourceImportDialog(
            createClient: () {
              fixture.close(tester);
              return fixture.createClient();
            },
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.test/source.js',
      );
      await tester.tap(find.text('Detect and preview'));
      await _until(
        tester,
        () =>
            fixture.adapters.isNotEmpty &&
            fixture.adapters.single.draining.isCompleted,
      );
      expect(fixture.adapters.single.entered.isCompleted, isFalse);
      expect(fixture.exits, 0);
      fixture.adapters.single.released.complete();
      await _until(tester, () => fixture.exits == 1);
    },
  );

  inspectionTest(
    'cleanup failure before disposal remains on the original window exit callback',
    (tester, fixture) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        fixture.app(
          ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => show
                ? SourceRepositoryCatalogPage(
                    repository: first,
                    createClient: fixture.createClient,
                  )
                : const Text('Removed'),
          ),
        ),
      );
      await _until(
        tester,
        () =>
            fixture.adapters.isNotEmpty &&
            fixture.adapters.single.entered.isCompleted,
      );
      final adapter = fixture.adapters.single;
      adapter.response.completeError(StateError('HTTP failed'));
      await _until(tester, () => adapter.draining.isCompleted);
      adapter.released.completeError(StateError('native cleanup failed'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNotNull);
      visible.value = false;
      await tester.pumpAndSettle();
      fixture.close(tester);
      await tester.pumpAndSettle();
      expect(fixture.exits, 0);
      expect(tester.takeException(), isNotNull);
      expect(find.text('Unable to close. Please try again.'), findsOneWidget);
    },
  );

  inspectionTest(
    'catalog replacement ignores old results but window still drains both requests',
    (tester, fixture) async {
      final repository = ValueNotifier(first);
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        fixture.app(
          ValueListenableBuilder<SourceRepository>(
            valueListenable: repository,
            builder: (_, value, _) => SourceRepositoryCatalogPage(
              repository: value,
              createClient: fixture.createClient,
            ),
          ),
        ),
      );
      await _until(
        tester,
        () =>
            fixture.adapters.length == 1 &&
            fixture.adapters.first.entered.isCompleted,
      );
      repository.value = second;
      await _until(
        tester,
        () =>
            fixture.adapters.length == 2 &&
            fixture.adapters.last.entered.isCompleted,
      );
      final old = fixture.adapters.first;
      final current = fixture.adapters.last;
      await _until(tester, () => old.draining.isCompleted);
      current.response.complete(
        ResponseBody.fromString(
          '[{"key":"new","name":"Current source","version":"1.0.0","fileName":"source.js"}]',
          200,
        ),
      );
      await _until(tester, () => current.draining.isCompleted);
      current.released.complete();
      await _until(
        tester,
        () => find.text('Current source').evaluate().isNotEmpty,
      );
      fixture.close(tester);
      await tester.pump();
      expect(fixture.exits, 0);
      old.released.complete();
      await _until(tester, () => fixture.exits == 1);
    },
  );

  inspectionTest(
    'removed import dialog leaves its native request in original window drain',
    (tester, fixture) async {
      await tester.pumpWidget(fixture.app(const Text('Home')));
      unawaited(
        fixture.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                SourceImportDialog(createClient: fixture.createClient),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.test/source.js',
      );
      await tester.tap(find.text('Detect and preview'));
      await _until(
        tester,
        () =>
            fixture.adapters.isNotEmpty &&
            fixture.adapters.single.entered.isCompleted,
      );
      fixture.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      final adapter = fixture.adapters.single;
      await _until(tester, () => adapter.draining.isCompleted);
      fixture.close(tester);
      await tester.pump();
      expect(fixture.exits, 0);
      adapter.released.complete();
      await _until(tester, () => fixture.exits == 1);
      expect(find.text('Source script detected'), findsNothing);
    },
  );

  inspectionTest(
    'idle preview cleanup failure stays on window and retries release only',
    (tester, fixture) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final file = _File()..releaseError = StateError('release');
      file.contents.complete(
        Uint8List.fromList('class Demo extends ComicSource {}'.codeUnits),
      );
      await tester.pumpWidget(
        fixture.app(
          ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => show
                ? SourceImportDialog(pickFile: () async => file)
                : const Text('Removed'),
          ),
        ),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await tester.pumpAndSettle();
      expect(find.text('Source script detected'), findsOneWidget);
      visible.value = false;
      await tester.pumpAndSettle();
      expect(file.releases, 1);
      expect(tester.takeException(), isA<FileSelectionCleanupFailure>());
      fixture.close(tester);
      await tester.pumpAndSettle();
      expect(fixture.exits, 0);
      expect(tester.takeException(), isA<FileSelectionCleanupFailure>());
      file.releaseError = null;
      await tester.tap(find.text('Retry'));
      await _until(tester, () => fixture.exits == 1);
      expect(file.reads, 1);
    },
  );

  inspectionTest(
    'script preview transfers its selected handle to the installation queue',
    (tester, fixture) async {
      final file = _File();
      file.contents.complete(
        Uint8List.fromList('class Demo extends ComicSource {}'.codeUnits),
      );
      await tester.pumpWidget(
        fixture.app(SourceImportDialog(pickFile: () async => file)),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install source'));
      await _until(
        tester,
        () =>
            fixture.queue.tasks.isNotEmpty &&
            !fixture.queue.tasks.single.active,
      );
      expect(fixture.queue.tasks.single.selection, same(file));
      await tester.pumpWidget(fixture.app(const Text('Removed')));
      await tester.pumpAndSettle();
      expect(file.releases, 0);
      fixture.queue.clearFinished();
      await tester.pumpAndSettle();
      expect(file.releases, 1);
    },
  );

  inspectionTest(
    'picker is single-flight and close waits its result without reading a late file',
    (tester, fixture) async {
      final picked = Completer<FileSelection?>();
      final file = _File();
      var picks = 0;
      await tester.pumpWidget(
        fixture.app(
          SourceImportDialog(
            pickFile: () {
              picks++;
              return picked.future;
            },
          ),
        ),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byType(OutlinedButton).first)
            .onPressed,
        isNull,
      );
      expect(picks, 1);
      fixture.close(tester);
      await tester.pump();
      expect(fixture.exits, 0);
      picked.complete(file);
      await _until(tester, () => fixture.exits == 1);
      expect(file.reads, 0);
      expect(file.releases, 1);
      expect(find.text('Source script detected'), findsNothing);
    },
  );

  inspectionTest(
    'close joins an accepted file read and suppresses its late preview',
    (tester, fixture) async {
      final file = _File();
      await tester.pumpWidget(
        fixture.app(SourceImportDialog(pickFile: () async => file)),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await _until(tester, () => file.reads == 1);
      fixture.close(tester);
      await tester.pump();
      expect(fixture.exits, 0);
      file.contents.complete(
        Uint8List.fromList('class Demo extends ComicSource {}'.codeUnits),
      );
      await _until(tester, () => fixture.exits == 1);
      expect(find.text('Source script detected'), findsNothing);
    },
  );

  inspectionTest(
    'selected relative catalog keeps its bytes for base URL correction',
    (tester, fixture) async {
      final file = _File();
      file.contents.complete(
        Uint8List.fromList(
          '[{"key":"one","name":"Selected source","version":"1.0.0","fileName":"one.js"}]'
              .codeUnits,
        ),
      );
      await tester.pumpWidget(
        fixture.app(SourceImportDialog(pickFile: () async => file)),
      );
      await tester.tap(find.text('Choose JS or JSON file'));
      await tester.pumpAndSettle();
      expect(find.text('Original source list URL'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).last,
        'https://example.test/index.json',
      );
      await tester.tap(find.text('Detect and preview'));
      await tester.pumpAndSettle();
      expect(find.text('Selected source'), findsOneWidget);
      expect(file.reads, 1);
      expect(file.releases, 0);
      fixture.close(tester);
      await _until(tester, () => fixture.exits == 1);
      expect(file.releases, 1);
    },
  );
}

class _File extends Fake implements FileSelection {
  int releases = 0;
  Object? releaseError;
  @override
  Future<void> dispose() async {
    releases++;
    if (releaseError != null) throw releaseError!;
  }

  final contents = Completer<Uint8List>();
  int reads = 0;
  @override
  String get name => 'source.json';
  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    return contents.future;
  }
}

class _PreviewManager extends Fake implements ComicSourceManager {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  ComicSource? find(String key) => null;
  @override
  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) async {
    beforeInstall();
    throw StateError('Invalid test script');
  }
}
