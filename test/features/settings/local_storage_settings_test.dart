import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/settings/app_controls.dart';
import 'package:venera_next/features/settings/local_storage_settings.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/harmonyos.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

import '../../support/ui_regression_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadUiRegressionFonts();
    final font = Platform.environment['STORAGE_AUTHORITY_QA_FONT'];
    if (font != null) {
      await (FontLoader(
        'StorageQA',
      )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    }
    final icons = Platform.environment['STORAGE_AUTHORITY_QA_ICONS'];
    if (icons != null) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(File(icons).readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  setUp(() async {
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'zh-CN';
    Log.isMuted = true;
    await AppTranslation.init();
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
  });

  Future<void> host(
    WidgetTester tester,
    _Manager manager, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    GlobalKey? boundary,
    bool includeAppLock = false,
  }) => tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: brightness,
          fontFamily:
              Platform.environment.containsKey('UI_REGRESSION_QA_DIRECTORY')
              ? uiRegressionFont
              : Platform.environment.containsKey('STORAGE_AUTHORITY_QA_FONT')
              ? 'StorageQA'
              : null,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  LocalStorageSettings(manager: manager),
                  if (includeAppLock) const AuthorizationRequiredSetting(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'HarmonyOS explains unavailable external storage without opening a picker',
    (tester) async {
      HarmonyOS.debugIsCurrent = true;
      addTearDown(() => HarmonyOS.debugIsCurrent = null);
      final calls = <MethodCall>[];
      const channel = HarmonyOS.channel;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final manager = _Manager()..blocked = false;
      await host(tester, manager);
      final action = tester.widget<TextButton>(find.byType(TextButton));
      expect(action.onPressed, isNull);
      expect(
        find.text(
          'HarmonyOS currently stores comics inside the app. Import external folders by copying their contents.'
              .tl,
        ),
        findsOneWidget,
      );
      final setting = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Set New Storage Path'.tl),
      );
      expect(setting.onTap, isNull);
      expect(setting.enabled, isFalse);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(manager.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HarmonyOS still permits recovery and disables relocation after recovery',
    (tester) async {
      HarmonyOS.debugIsCurrent = true;
      addTearDown(() => HarmonyOS.debugIsCurrent = null);
      final manager = _Manager();
      manager.recover = () async => manager.blocked = false;
      await host(tester, manager);
      expect(manager.pathReads, 0);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(manager.calls, 1);
      expect(find.text('/moved/library'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final spec in [
    (const Size(375, 667), 1.0, Brightness.light),
    (const Size(667, 375), 3.2, Brightness.dark),
    (const Size(1024, 768), 2.0, Brightness.light),
  ]) {
    testWidgets(
      'HarmonyOS storage and app-lock explanations fit at ${spec.$1}, scale ${spec.$2}',
      (tester) async {
        HarmonyOS.debugIsCurrent = true;
        addTearDown(() => HarmonyOS.debugIsCurrent = null);
        final previousLock = appdata.settings['authorizationRequired'];
        appdata.settings['authorizationRequired'] = false;
        addTearDown(
          () => appdata.settings['authorizationRequired'] = previousLock,
        );
        tester.view.physicalSize = spec.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        await host(
          tester,
          _Manager()..blocked = false,
          scale: spec.$2,
          brightness: spec.$3,
          boundary: boundary,
          includeAppLock: true,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed,
          isNull,
        );
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          isNull,
        );
        await captureUiRegression(
          tester,
          boundary,
          'settings-storage-${spec.$1.width.toInt()}-${spec.$2}',
        );
        await tester.ensureVisible(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(find.byType(SwitchListTile).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureUiRegression(
          tester,
          boundary,
          'settings-lock-${spec.$1.width.toInt()}-${spec.$2}',
        );
      },
    );
  }

  testWidgets(
    'failed storage recovery keeps retry available without reading an unknown path',
    (tester) async {
      final manager = _Manager();
      final pending = Completer<void>();
      manager.recover = () => pending.future;
      await host(tester, manager);
      expect(manager.pathReads, 0);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(manager.calls, 1);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pending.completeError(StateError('journal unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Local storage needs recovery'.tl), findsOneWidget);
      expect(find.text('Retry'.tl), findsOneWidget);
      expect(manager.pathReads, 0);
      manager.recover = () async => manager.blocked = false;
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(manager.calls, 2);
      expect(find.text('/moved/library'), findsOneWidget);
      expect(find.text('Set'.tl), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unmount during recovery allows completion without updating a disposed page',
    (tester) async {
      final manager = _Manager();
      final pending = Completer<void>();
      manager.recover = () => pending.future;
      await host(tester, manager);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Replacement'))),
      );
      manager.blocked = false;
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Replacement'), findsOneWidget);
      expect(manager.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard retry is accessible and recovery status is a live region',
    (tester) async {
      final manager = _Manager()..recover = () async {};
      await host(tester, manager);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Retry'.tl), findsWidgets);
      final status = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('Local storage needs recovery'.tl),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(status.properties.liveRegion, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(manager.calls, 1);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final spec in [
    (const Size(375, 667), 1.0, Brightness.light),
    (const Size(667, 375), 3.2, Brightness.dark),
    (const Size(1024, 768), 2.0, Brightness.light),
  ]) {
    testWidgets(
      'recovery controls remain usable at ${spec.$1} and text scale ${spec.$2}',
      (tester) async {
        tester.view.physicalSize = spec.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final manager = _Manager()..recover = () async {};
        final boundary = GlobalKey();
        await host(
          tester,
          manager,
          scale: spec.$2,
          brightness: spec.$3,
          boundary: boundary,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(TextButton));
        await tester.pumpAndSettle();
        expect(find.byType(TextButton).hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byType(TextButton)).height,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
        final output = Platform.environment['STORAGE_AUTHORITY_QA_DIRECTORY'];
        if (output != null) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File(
              '$output/storage-${spec.$1.width.toInt()}-${spec.$1.height.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byType(TextButton));
        await tester.pumpAndSettle();
        expect(manager.calls, 1);
        expect(manager.pathReads, 0);
      },
    );
  }
}

class _Manager extends Fake implements LocalManager {
  bool blocked = true;
  int calls = 0;
  int pathReads = 0;
  late Future<void> Function() recover;
  @override
  bool get requiresStorageRecovery => blocked;
  @override
  String get path {
    pathReads++;
    if (blocked) throw StateError('Unknown path must not be displayed');
    return '/moved/library';
  }

  @override
  Future<void> recoverStorage() {
    calls++;
    return recover();
  }
}
