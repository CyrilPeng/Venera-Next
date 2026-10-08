import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source_installations_scope.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'source_editor_ownership_test.dart' show drain, pumpUntil;

class _UiHandler implements JsUiMessageHandler {
  _UiHandler(this.action);
  final VoidCallback action;
  @override
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) {
    action();
    return null;
  }
}

const _script = '''
class SettingActionSource extends ComicSource {
  key = 'setting_action'; name = 'Setting action source'; version = '1.0.0';
  minAppVersion = '1.0.0'; mode = 'plain'; calls = 0;
  comic = {loadInfo: () => ({title:'Book',cover:'',tags:{}}), loadEp: () => []};
  act(...args) {
    this.calls++;
    this.arguments = args;
    if (this.mode === 'reenter') sendMessage({method: 'UI'});
    if (this.mode === 'pending' || this.mode === 'reenter') return new Promise((resolve, reject) => {
      (globalThis.settingFinishes ??= []).push({resolve, reject});
    });
    const callback = () => 42;
    const graph = {message: 'setting action failed', callback, aliases: [callback, {callback}]};
    if (this.mode === 'graph') return graph;
    if (this.mode === 'asyncGraph') return Promise.resolve(graph);
    if (this.mode === 'throw') throw graph;
    if (this.mode === 'reject') return Promise.reject(graph);
    return 73;
  }
  get settings() { return {action: {
    type: 'callback', title: 'Source action', buttonText: 'Run source action',
    callback: (...args) => this.act(...args)
  }}; }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late JsEngine engine;
  late ComicSourceManager manager;
  late ComicSource source;
  late SourceInstallations queue;
  late SelectionTaskRegistry tasks;
  late GlobalKey<NavigatorState> navigator;
  late bool allowed;
  final messages = <String>[];

  Future<void> prepare(WidgetTester tester) async {
    rootBundle.clear();
    messages.clear();
    allowed = true;
    tasks = SelectionTaskRegistry();
    navigator = GlobalKey<NavigatorState>();
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
      root = Directory.systemTemp.createTempSync('source-setting-action-');
      Directory('${root.path}/comic_source').createSync();
      App.dataPath = root.path;
      App.cachePath = root.path;
      App.version = '9.0.0';
      App.isInitialized = false;
      Log.isMuted = true;
      await appdata.init();
      await appdata.updateSettings(
        (draft) => draft['language'] = 'en-US',
        sync: false,
      );
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      engine = JsEngine();
      await engine.init();
      manager = ComicSourceManager();
      source = await ComicSourceParser().parse(
        _script,
        '${root.path}/comic_source/action.js',
      );
      manager.add(source);
      queue = SourceInstallations(
        manager: manager,
        repositories: SourceRepositories.instance,
        createClient: Dio.new,
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      try {
        await drain(tester, () async {
          try {
            engine.runCode('''void (globalThis.settingFinishes ?? []).forEach(
              entry => entry.resolve(null))''');
          } on StateError {
            // Some tests deliberately close this exact engine first.
          }
          await tasks.closeAndWait();
          await queue.closeAndWait();
          await manager.closeAndWait();
          await engine.closeAndWait();
          await appdata.saveData(false);
        });
      } finally {
        await tester.runAsync(() => root.delete(recursive: true));
        Log.isMuted = false;
        registerShowMessageHandler((_, _) {});
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        );
      }
    });
  }

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    bool window = false,
    VoidCallback? onExit,
    double textScale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) {
        Widget content = MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: NavigationAdmission(
            allowsNavigation: () => allowed,
            child: SelectionTasksScope(
              registry: tasks,
              child: SourceInstallationsScope(queue: queue, child: child!),
            ),
          ),
        );
        if (window) content = WindowFrame(content, onExit: onExit);
        return content;
      },
      home: const ComicSourcePage(),
    ),
  );

  Future<void> expand(WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 10 &&
          find
              .byTooltip('Show source settings')
              .hitTestable()
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -120));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Show source settings'));
    await tester.pumpAndSettle();
  }

  void mode(String value) => engine.runCode(
    "void (ComicSource.sources.setting_action.mode = '$value')",
  );
  int calls() =>
      engine.runCode('ComicSource.sources.setting_action.calls') as int;
  Button actionButton(WidgetTester tester) => tester.widget<Button>(
    find.byWidgetPredicate(
      (widget) =>
          widget is Button &&
          widget.child is Text &&
          (widget.child as Text).data == 'Run source action',
    ),
  );

  for (final value in ['graph', 'asyncGraph', 'throw', 'reject']) {
    testWidgets('native setting $value releases all unused result references', (
      tester,
    ) async {
      await prepare(tester);
      await show(tester);
      await expand(tester);
      mode(value);
      await tester.tap(find.text('Run source action'));
      await tester.pump();
      await pumpUntil(tester, () => !actionButton(tester).isLoading);
      await tester.pumpAndSettle();
      expect(calls(), 1);
      expect(
        engine.runCode('ComicSource.sources.setting_action.arguments'),
        [],
      );
      expect(messages.length, value == 'throw' || value == 'reject' ? 1 : 0);
      expect(tester.takeException(), isNull);
      // Native close in teardown detects raw references as well as owned ones.
    });
  }

  for (final window in [false, true]) {
    testWidgets(
      'original ${window ? 'window' : 'application'} joins a collapsed callback',
      (tester) async {
        await prepare(tester);
        var exits = 0;
        await show(tester, window: window, onExit: () => exits++);
        await expand(tester);
        mode('pending');
        await tester.tap(find.text('Run source action'));
        await tester.pump();
        expect(calls(), 1);
        await tester.tap(find.byTooltip('Hide source settings'));
        await tester.pump();
        var closed = false;
        Future<void>? closing;
        if (window) {
          (tester.state(find.byType(WindowFrame)) as WindowListener)
              .onWindowClose();
        } else {
          closing = tasks.closeAndWait().then((_) => closed = true);
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pump();
        expect(closed, isFalse);
        expect(exits, 0);
        engine.runCode('void settingFinishes[0].resolve({callback: () => 42})');
        await pumpUntil(tester, () => window ? exits == 1 : closed);
        if (closing != null) await closing;
        expect(messages, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'theme rebuild does not release the active click or admit a duplicate',
    (tester) async {
      await prepare(tester);
      await show(tester);
      await expand(tester);
      mode('pending');
      await tester.tap(find.text('Run source action'));
      await tester.pump();
      await show(tester, dark: true);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      final button = actionButton(tester);
      button.onPressed();
      await tester.pump();
      expect(calls(), 1);
      expect(button.isLoading, isTrue);
      engine.runCode('void settingFinishes[0].resolve(null)');
      await pumpUntil(tester, () => !actionButton(tester).isLoading);
      expect(messages, isEmpty);
    },
  );

  testWidgets('frozen and covered routes reject an old button callback', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await expand(tester);
    final click = actionButton(tester).onPressed;
    allowed = false;
    click();
    await tester.pumpAndSettle();
    expect(calls(), 0);
    allowed = true;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    click();
    await tester.pumpAndSettle();
    expect(calls(), 0);
    expect(messages, isEmpty);
  });

  testWidgets(
    'a replaced application registry cannot inherit the old callback',
    (tester) async {
      await prepare(tester);
      await show(tester);
      await expand(tester);
      mode('pending');
      await tester.tap(find.text('Run source action'));
      await tester.pump();
      final original = tasks;
      tasks = SelectionTaskRegistry();
      await show(tester);
      await drain(tester, tasks.closeAndWait);
      var closed = false;
      final closing = original.closeAndWait().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      engine.runCode("void settingFinishes[0].reject('original late failure')");
      await pumpUntil(tester, () => closed);
      await closing;
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-key replacement cannot receive an old callback result', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await expand(tester);
    mode('pending');
    await tester.tap(find.text('Run source action'));
    await tester.pump();
    final original = source;
    manager.remove(original.key);
    await tester.runAsync(() async {
      source = await ComicSourceParser().parse(
        _script.replaceFirst("version = '1.0.0'", "version = '2.0.0'"),
        '${root.path}/comic_source/replacement.js',
      );
      manager.add(source);
    });
    await tester.pump();
    var closed = false;
    final closing = tasks.closeAndWait().then((_) => closed = true);
    await tester.pump();
    expect(closed, isFalse);
    engine.runCode('void settingFinishes[0].resolve({callback: () => 42})');
    await pumpUntil(tester, () => closed);
    await closing;
    expect(manager.find(original.key), same(source));
    expect(source.version, '2.0.0');
    expect(calls(), 0);
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late rejection cannot show feedback over a new route', (
    tester,
  ) async {
    await prepare(tester);
    await show(tester);
    await expand(tester);
    mode('pending');
    await tester.tap(find.text('Run source action'));
    await tester.pump();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New route')),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    engine.runCode(
      "void settingFinishes[0].reject({message:'late failure', callback:()=>42})",
    );
    await drain(tester, tasks.closeAndWait);
    expect(find.text('New route'), findsOneWidget);
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'synchronous JS reentry sees loading and registered original-host work',
    (tester) async {
      await prepare(tester);
      await show(tester);
      await expand(tester);
      var closed = false, reentered = false;
      Future<void>? closing;
      final click = actionButton(tester).onPressed;
      engine.bindUiMessageHandler(
        _UiHandler(() {
          // The rebuilt button need not have been painted yet. Reenter the same
          // real State callback and verify it cannot invoke the source a second time.
          click();
          reentered = true;
          closing = tasks.closeAndWait().then((_) => closed = true);
        }),
      );
      mode('reenter');
      click();
      await tester.pump();
      expect(reentered, isTrue);
      expect(calls(), 1);
      expect(closed, isFalse);
      expect(actionButton(tester).isLoading, isTrue);
      engine.runCode('void settingFinishes[0].resolve(null)');
      await pumpUntil(tester, () => closed);
      await closing;
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached settings fallback uses the same invocation completion boundary',
    (tester) async {
      await prepare(tester);
      await show(tester);
      engine.runCode(
        '''void Object.defineProperty(ComicSource.sources.setting_action, 'settings', {
      get: () => { throw new Error('settings getter failed'); }
    })''',
      );
      await expand(tester);
      mode('asyncGraph');
      await tester.tap(find.text('Run source action'));
      await tester.pump();
      await pumpUntil(tester, () => !actionButton(tester).isLoading);
      expect(calls(), 1);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(375, 740), const Size(812, 375)]) {
    testWidgets('callback progress remains usable with 2x text at $size', (
      tester,
    ) async {
      await prepare(tester);
      final semantics = tester.ensureSemantics();
      try {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await show(tester, dark: size.width < 400, textScale: 2);
        await expand(tester);
        for (
          var i = 0;
          i < 10 &&
              find.text('Run source action').hitTestable().evaluate().isEmpty;
          i++
        ) {
          await tester.drag(
            find.byType(NestedScrollView),
            const Offset(0, -80),
          );
          await tester.pumpAndSettle();
        }
        final click = actionButton(tester).onPressed;
        mode('pending');
        click();
        await tester.pump();
        expect(actionButton(tester).isLoading, isTrue);
        final semanticButton = tester.getSemantics(
          find.bySemanticsLabel('Run source action'),
        );
        expect(semanticButton.flagsCollection.isButton, isTrue);
        expect(semanticButton.flagsCollection.isEnabled, Tristate.isFalse);
        click();
        await tester.pump();
        expect(calls(), 1);
        engine.runCode('void settingFinishes[0].resolve(null)');
        await pumpUntil(tester, () => !actionButton(tester).isLoading);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
