import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:window_manager/window_manager.dart';
import '../../support/comic_source_fixture.dart';

class _Storage extends SourceDataStorage {
  Future<void> Function()? before;
  int writes = 0;
  Map saved = {};
  @override
  Future<void> write(String path, String key, String contents) async {
    writes++;
    await before?.call();
    saved = jsonDecode(contents) as Map;
  }
}

const _settings = <String, Map<String, dynamic>>{
  'enabled': {
    'type': 'switch',
    'title': 'Enable source option',
    'default': false,
  },
  'mode': {
    'type': 'select',
    'title': 'Choose a source display mode',
    'default': 'one',
    'options': [
      {'value': 'one', 'text': 'First option'},
      {'value': 'two', 'text': 'Second option'},
    ],
  },
  'text': {'type': 'input', 'title': 'Source text setting', 'default': ''},
};

void main() {
  late ComicSourceManager manager;
  late ComicSource source;
  late _Storage storage;
  late GlobalKey<NavigatorState> navigator;
  late GlobalKey image;
  final messages = <String>[];
  int exits = 0;
  setUpAll(() async {
    final path = Platform.environment['VENERA_SOURCE_DATA_QA_FONT'];
    if (path != null) {
      final font = FontLoader('SourceDataQA')
        ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
      await font.load();
    }
    final icons = Platform.environment['VENERA_SOURCE_DATA_QA_ICONS'];
    if (icons != null) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(File(icons).readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  setUp(() {
    final root = Directory.systemTemp.createTempSync('source-data-ui-');
    App.dataPath = root.path;
    addTearDown(() => root.deleteSync(recursive: true));
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
    messages.clear();
    registerShowMessageHandler((_, message) => messages.add(message));
    navigator = GlobalKey<NavigatorState>();
    image = GlobalKey();
    exits = 0;
  });

  Future<void> show(
    WidgetTester tester, {
    bool window = false,
    double scale = 1,
    bool dark = false,
    AccountConfig? account,
  }) async {
    storage = _Storage();
    source = ComicSourceFixture(
      key: 'data_ui',
      settings: _settings,
      account: account,
      dataStorage: storage,
    );
    manager = ComicSourceManager()..add(source);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() async {
      storage.before = null;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(manager.closeAndWait);
      registerShowMessageHandler((_, _) {});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: Platform.environment['VENERA_SOURCE_DATA_QA_FONT'] == null
              ? null
              : 'SourceDataQA',
        ),
        builder: (context, child) {
          final content = RepaintBoundary(
            key: image,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
          );
          return window
              ? WindowFrame(
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: content,
                  ),
                  onExit: () => exits++,
                )
              : content;
        },
        home: const ComicSourcePage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Show source settings').hitTestable(),
      150,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show source settings').hitTestable());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'building settings leaves data unchanged; queued switch waits for admission',
    (tester) async {
      await show(tester);
      expect(source.data, isEmpty);
      expect(storage.writes, 0);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(source.data, isEmpty);
      expect(
        tester
            .state<SettingsSaveState>(
              find.byWidgetPredicate(
                (widget) =>
                    widget.runtimeType.toString() == '_SliverComicSource',
              ),
            )
            .savingSettings,
        isTrue,
      );
      release.complete();
      await tester.pumpAndSettle();
      await exclusive;
      expect(storage.saved, {
        'settings': {'enabled': true},
      });
    },
  );

  testWidgets('failed setting retry preserves later source changes', (
    tester,
  ) async {
    await show(tester);
    storage.before = () async => throw StateError('write failed');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    storage.before = null;
    await source.editData((draft) {
      draft['settings']['enabled'] = false;
      draft['later'] = true;
    });
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(storage.saved, {
      'settings': {'enabled': false},
      'later': true,
    });
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('input dialog waits for its save before returning', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'captured');
    final release = Completer<void>();
    storage.before = () => release.future;
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    unawaited(navigator.currentState!.maybePop());
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    release.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(storage.saved['settings']['text'], 'captured');
  });

  testWidgets('old dropdown result cannot edit a replacement source', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byType(DropdownButtonFormField<dynamic>));
    await tester.pumpAndSettle();
    final replacement = ComicSourceFixture(
      key: source.key,
      settings: _settings,
      dataStorage: storage,
    );
    manager.remove(source.key);
    manager.add(replacement);
    await tester.pump();
    await tester.tap(find.text('Second option').last);
    await tester.pumpAndSettle();
    expect(source.data, isEmpty);
    expect(replacement.data, isEmpty);
    expect(storage.writes, 0);
  });

  testWidgets(
    'window waits for accepted setting after its control is unmounted',
    (tester) async {
      await show(tester, window: true);
      final release = Completer<void>();
      storage.before = () => release.future;
      await tester.tap(find.byType(Switch));
      await tester.pump();
      // Removing this source removes its keyed settings owner while keeping the window.
      manager.remove(source.key);
      await tester.pump();
      final frame = tester.state(find.byType(WindowFrame)) as WindowListener;
      frame.onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(storage.saved['settings']['enabled'], isTrue);
    },
  );

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['VENERA_SOURCE_DATA_QA_OUTPUT'];
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary =
          image.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      rendered.dispose();
    });
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder.hitTestable(),
      150,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final dark in [false, true]) {
      testWidgets('source settings large text $size dark=$dark', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await show(tester, scale: 3.2, dark: dark);
        await tester.scrollUntilVisible(
          find.byType(DropdownButtonFormField<dynamic>).hitTestable(),
          150,
          scrollable: find
              .byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(
          tester,
          'settings-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        await tester.tap(
          find.byType(DropdownButtonFormField<dynamic>).hitTestable(),
        );
        await tester.pumpAndSettle();
        await capture(
          tester,
          'options-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        await tester.tap(find.text('Second option').last);
        await tester.pumpAndSettle();
        expect(storage.saved['settings']['mode'], 'two');
        await reveal(tester, find.byTooltip('Edit'));
        await tester.tap(find.byTooltip('Edit').hitTestable());
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Source value');
        await tester.pumpAndSettle();
        await capture(
          tester,
          'input-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(storage.saved['settings']['text'], 'Source value');
      });

      testWidgets('source login large text $size dark=$dark', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await show(
          tester,
          scale: 3.2,
          dark: dark,
          account: AccountConfig(
            (_, _) async => const Res(true),
            'https://example.test/',
            'https://example.test/register',
            () {},
            null,
            null,
            null,
            null,
          ),
        );
        await reveal(tester, find.text('Log in'));
        await tester.tap(find.text('Log in').hitTestable());
        await tester.pumpAndSettle();
        await capture(
          tester,
          'login-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        await reveal(tester, find.text('Create Account'));
        await capture(
          tester,
          'login-actions-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
