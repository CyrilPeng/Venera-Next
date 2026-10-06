import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_import_dialog.dart';
import 'package:venera_next/features/comic_source/source_installations_scope.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_repository_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

Future<void> _flush(WidgetTester tester, Future<void> work) async {
  var done = false;
  Object? failure;
  work.then<void>(
    (_) => done = true,
    onError: (Object e) {
      failure = e;
      done = true;
    },
  );
  await _until(tester, () => done);
  expect(failure, isNull);
}

SettingsSaveState _owner(WidgetTester tester) =>
    tester.allStates.whereType<SettingsSaveState>().single;

class _Fixture {
  _Fixture(this.root, this.adapter, this.queue);
  final SourceInstallations queue;
  final Directory root;
  final _Catalog adapter;
  final navigator = GlobalKey<NavigatorState>();
  final image = GlobalKey();
  int exits = 0;
  Widget host({Widget? child, bool window = false, double textScale = 1}) =>
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          fontFamily:
              Platform.environment['VENERA_SOURCE_PREFERENCES_QA_FONT'] == null
              ? null
              : 'SourcePreferencesQA',
        ),
        builder: (context, child) {
          Widget content = RepaintBoundary(
            key: image,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: true,
              ),
              child: child!,
            ),
          );
          if (window) {
            content = WindowFrame(
              Padding(padding: const EdgeInsets.only(top: 48), child: content),
              onExit: () => exits++,
            );
          }
          return SourceInstallationsScope(queue: queue, child: content);
        },
        home: Scaffold(body: child ?? const SourceRepositoriesPanel()),
      );
  Map get saved =>
      (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
              as Map)['settings']
          as Map;
}

Future<_Fixture> _prepare(WidgetTester tester) async {
  final root = Directory.systemTemp.createTempSync('source-form-');
  final previous = appdata.captureImportCheckpoint();
  App.dataPath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['comicSourceRepositories'] = [];
  appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
  final manager = ComicSourceManager();
  final adapter = _Catalog();
  final queue = SourceInstallations(
    manager: manager,
    repositories: SourceRepositories.instance,
    createClient: Dio.new,
  );
  SourceRepositories.debugCreateDio = () => Dio()..httpClientAdapter = adapter;
  registerShowMessageHandler((_, _) {});
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  addTearDown(() async {
    if (adapter.release?.isCompleted == false) adapter.release!.complete();
    await tester.pumpWidget(const SizedBox());
    await _flush(tester, appdata.saveData(false));
    await _flush(tester, queue.closeAndWait());
    await _flush(tester, manager.closeAndWait());
    await _flush(
      tester,
      appdata.restoreImportCheckpoint(previous, persist: false),
    );
    SourceRepositories.debugCreateDio = null;
    root.deleteSync(recursive: true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });
  return _Fixture(root, adapter, queue);
}

Future<void> _editor(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Add repository'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, 'Example');
  await tester.enterText(
    find.byType(TextField).last,
    'https://example.test/catalog.json',
  );
}

Future<void> _press(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['VENERA_SOURCE_PREFERENCES_QA_FONT'];
    if (path != null) {
      final font = FontLoader('SourcePreferencesQA')
        ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
      await font.load();
    }
  });
  testWidgets('editor retry reuses one catalog check and one repository ID', (
    tester,
  ) async {
    final fixture = await _prepare(tester);
    await tester.pumpWidget(fixture.host());
    await _editor(tester);
    final blocked = Directory('${fixture.root.path}/appdata.json.tmp')
      ..createSync();
    await _press(tester, 'Save');
    await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
    final id = SourceRepositories.instance.all.single.id;
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isFalse,
    );
    blocked.deleteSync();
    await _flush(tester, _owner(tester).retrySettingsSave());
    await tester.pumpAndSettle();
    expect(fixture.adapter.requests, 1);
    expect(fixture.saved['comicSourceRepositories'].single['id'], id);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('catalog validation failure leaves editor inputs editable', (
    tester,
  ) async {
    final fixture = await _prepare(tester);
    fixture.adapter.contents = 'invalid';
    await tester.pumpWidget(fixture.host());
    await _editor(tester);
    await _press(tester, 'Save');
    await _flush(tester, _owner(tester).waitForSettingsSave());
    expect(SourceRepositories.instance.all, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isTrue,
    );
    expect(
      find.text('The address must return a source list in JSON format.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'forced editor removal hands catalog check and save to original window',
    (tester) async {
      final fixture = await _prepare(tester);
      fixture.adapter.release = Completer<void>();
      await tester.pumpWidget(fixture.host(window: true));
      await _editor(tester);
      await _press(tester, 'Save');
      final owner = _owner(tester);
      final route = ModalRoute.of(owner.context)!;
      fixture.navigator.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(fixture.exits, 0);
      fixture.adapter.release!.complete();
      await _flush(tester, owner.waitForSettingsSave());
      await _until(tester, () => fixture.exits == 1);
      expect(
        fixture.saved['comicSourceRepositories'].single['name'],
        'Example',
      );
    },
  );

  testWidgets(
    'repository removal keeps dialog and retries failed persistence',
    (tester) async {
      final fixture = await _prepare(tester);
      appdata.settings['comicSourceRepositories'] = [
        const SourceRepository(
          id: 'one',
          name: 'One',
          url: 'https://one.test',
        ).toJson(),
      ];
      await tester.pumpWidget(fixture.host());
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove repository'));
      await tester.pumpAndSettle();
      final blocked = Directory('${fixture.root.path}/appdata.json.tmp')
        ..createSync();
      await _press(tester, 'Remove repository');
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(SourceRepositories.instance.all, isEmpty);
      blocked.deleteSync();
      await _flush(tester, _owner(tester).retrySettingsSave());
      await tester.pumpAndSettle();
      expect(fixture.saved['comicSourceRepositories'], isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'origin picker retries unlink persistence after memory already changed',
    (tester) async {
      final fixture = await _prepare(tester);
      appdata.settings['comicSourceOrigins'] = {
        'source': const SourceOrigin(
          kind: 'repository',
          repositoryId: 'one',
        ).toJson(),
      };
      await tester.pumpWidget(
        fixture.host(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSourceOriginPicker(context, _Source()),
              child: const Text('Origin'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Origin'));
      await tester.pumpAndSettle();
      final blocked = Directory('${fixture.root.path}/appdata.json.tmp')
        ..createSync();
      await tester.tap(find.text('Remove repository link'));
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      blocked.deleteSync();
      await _flush(tester, _owner(tester).retrySettingsSave());
      await tester.pumpAndSettle();
      expect(
        (fixture.saved['comicSourceOrigins'] as Map).containsKey('source'),
        isFalse,
      );
      expect(find.byType(SimpleDialog), findsNothing);
    },
  );

  testWidgets(
    'imported repository retry flushes the original request without duplicate install',
    (tester) async {
      final fixture = await _prepare(tester);
      final tasks = fixture.queue.tasks.length;
      final client = Dio()..httpClientAdapter = fixture.adapter;
      addTearDown(client.close);
      await tester.pumpWidget(
        fixture.host(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SourceImportDialog(createClient: () => client),
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.test/catalog.json',
      );
      await _press(tester, 'Detect and preview');
      await _until(
        tester,
        () => find.text('Save repository').evaluate().isNotEmpty,
      );
      final blocked = Directory('${fixture.root.path}/appdata.json.tmp')
        ..createSync();
      await _press(tester, 'Save repository');
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      final id = SourceRepositories.instance.all.single.id;
      blocked.deleteSync();
      await _flush(tester, _owner(tester).retrySettingsSave());
      await tester.pumpAndSettle();
      expect(fixture.saved['comicSourceRepositories'].single['id'], id);
      expect(fixture.queue.tasks.length, tasks);
      expect(fixture.adapter.requests, 1);
    },
  );

  testWidgets('editor back waits for the accepted catalog check and save', (
    tester,
  ) async {
    final fixture = await _prepare(tester);
    fixture.adapter.release = Completer<void>();
    await tester.pumpWidget(fixture.host());
    await _editor(tester);
    await _press(tester, 'Save');
    final owner = _owner(tester);
    unawaited(fixture.navigator.currentState!.maybePop());
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    fixture.adapter.release!.complete();
    await _flush(tester, owner.waitForSettingsSave());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.saved['comicSourceRepositories'].single['name'], 'Example');
  });

  testWidgets(
    'removed import dialog finishes save in original window without dispatching installs',
    (tester) async {
      final fixture = await _prepare(tester);
      fixture.adapter.contents =
          '[{"key":"newsource","name":"New source","version":"1.0.0","url":"https://example.test/source.js"}]';
      final client = Dio()..httpClientAdapter = fixture.adapter;
      addTearDown(client.close);
      final tasks = fixture.queue.tasks.length;
      await tester.pumpWidget(
        fixture.host(
          window: true,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SourceImportDialog(createClient: () => client),
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.test/catalog.json',
      );
      await _press(tester, 'Detect and preview');
      await _until(
        tester,
        () => find.text('Install selected (1)').evaluate().isNotEmpty,
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await _press(tester, 'Install selected (1)');
      final owner = _owner(tester);
      fixture.navigator.currentState!.removeRoute(
        ModalRoute.of(owner.context)!,
      );
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(fixture.exits, 0);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      await _until(tester, () => fixture.exits == 1);
      expect(fixture.saved['comicSourceRepositories'], hasLength(1));
      expect(fixture.queue.tasks.length, tasks);
    },
  );

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('editor supports $size with dark large text and reduced motion', (
      tester,
    ) async {
      final fixture = await _prepare(tester);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(fixture.host(textScale: 3.2));
      await _editor(tester);
      expect(tester.takeException(), isNull);
      final button = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(button);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      await tester.ensureVisible(find.byType(TextField).last);
      await tester.pumpAndSettle();
      {
        final boundary =
            fixture.image.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            expect(bytes, isNotNull);
            final directory =
                Platform.environment['VENERA_SOURCE_PREFERENCES_SCREENSHOTS'];
            if (directory != null) {
              File(
                '$directory/source-repository-editor-${size.width.toInt()}x${size.height.toInt()}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
            }
          } finally {
            image.dispose();
          }
        });
      }
    });
  }
}

class _Catalog implements HttpClientAdapter {
  int requests = 0;
  String contents = '[]';
  Completer<void>? release;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    await release?.future;
    return ResponseBody.fromString(contents, 200);
  }

  @override
  void close({bool force = false}) {}
}

class _Source implements ComicSource {
  @override
  String get key => 'source';
  @override
  String get name => 'Source';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
