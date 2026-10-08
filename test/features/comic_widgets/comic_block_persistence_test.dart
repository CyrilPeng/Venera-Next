import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/message.dart' show ContentDialog;
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_widgets/comic_tile.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:window_manager/window_manager.dart';

const _comic = Comic(
  'alpha, beta',
  '',
  'id',
  null,
  ['group:tag'],
  '',
  'source',
  null,
  null,
);

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? error;
  operation.then(
    (_) => done = true,
    onError: (Object value) {
      error = value;
      done = true;
    },
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done, isTrue);
  expect(error, isNull);
  await tester.pump();
}

void main() {
  App.dataPath = Directory.systemTemp.path;
  late Directory root;
  late List<String> messages;
  setUp(() {
    root = Directory.systemTemp.createTempSync('comic-block-');
    final previousPath = App.dataPath;
    final previous = appdata.captureImportCheckpoint();
    App.dataPath = root.path;
    appdata.settings['blockedWords'] = ['old', 'old'];
    appdata.settings['blockedCommentWords'] = ['comment'];
    appdata.settings['extension'] = {'keep': true};
    messages = [];
    registerShowMessageHandler((_, message) => messages.add(message));
    addTearDown(() async {
      await appdata.restoreImportCheckpoint(previous, persist: false);
      App.dataPath = previousPath;
      registerShowMessageHandler((_, _) {});
      root.deleteSync(recursive: true);
    });
  });
  Future<void> open(
    WidgetTester tester,
    VoidCallback onBlocked, {
    ImageWork? work,
    VoidCallback? onExit,
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          );
          return onExit == null
              ? content
              : WindowFrame(content, onExit: onExit);
        },
        home: Scaffold(
          body: SettingsSaveScope(
            work: work ?? ImageWork(),
            child: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => ComicTile(
                    comic: _comic,
                    onBlocked: onBlocked,
                  ).block(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OptionChip, 'alpha'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'failed save retains selection and retry does not duplicate or overwrite other words',
    (tester) async {
      var callbacks = 0;
      await open(tester, () => callbacks++);
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Retry'), findsOneWidget);
      expect(callbacks, 0);
      expect(messages, isNot(contains('Blocked')));
      expect(
        tester
            .widget<OptionChip>(find.widgetWithText(OptionChip, 'alpha'))
            .isSelected,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Block'))
            .onPressed,
        isNull,
      );
      // The app retains published values after a potentially partial disk write.
      expect(appdata.settings['blockedWords'], ['old', 'old', 'alpha']);
      appdata.settings['blockedWords'] = [
        'concurrent',
        ...appdata.settings['blockedWords'] as List,
      ];
      blocked.deleteSync();
      await tester.tap(find.text('Retry'));
      await _flush(tester, appdata.saveData(false));
      await tester.pumpAndSettle();
      final saved = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings'];
      expect(saved['blockedWords'], ['concurrent', 'old', 'old', 'alpha']);
      expect(saved['extension'], {'keep': true});
      expect(callbacks, 1);
      expect(messages.where((message) => message == 'Blocked'), hasLength(1));
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'removed root dialog retains original reader and window ownership without late UI callbacks',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (_) async => false,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      final work = ImageWork();
      var callbacks = 0, exits = 0;
      await open(tester, () => callbacks++, work: work, onExit: () => exits++);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pump();
      var drained = false;
      final drain = work.prepareForExit().then((resume) {
        drained = true;
        resume();
      });
      final route = ModalRoute.of(tester.element(find.byType(ContentDialog)))!;
      appNavigation.rootNavigatorKey.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      final drainedEarly = drained, exitsEarly = exits;
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, drain, appdata.saveData(false)]),
      );
      for (var i = 0; i < 20 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(drainedEarly, isFalse);
      expect(exitsEarly, 0);
      expect(exits, 1);
      expect(callbacks, 0);
      expect(messages, isEmpty);
      expect(appdata.settings['blockedWords'], ['old', 'old', 'alpha']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scenario in [
    (size: const Size(375, 740), dark: true, scale: 2.0),
    (size: const Size(812, 375), dark: false, scale: 1.0),
  ]) {
    testWidgets('block selection and pending feedback fit $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, () {}, dark: scenario.dark, scale: scenario.scale);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pump();
      final pending = find.byType(CircularProgressIndicator).evaluate().length;
      final layoutError = tester.takeException();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Block'),
      );
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      await tester.pumpAndSettle();
      expect(pending, 1);
      expect(button.onPressed, isNull);
      expect(layoutError, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'block waits for admission, merges current draft and then reports success',
    (tester) async {
      var callbacks = 0;
      await open(tester, () => callbacks++);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final earlier = appdata.updateSettings(
        (draft) => draft['blockedWords'] = ['earlier', 'old', 'old'],
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pump();
      final before = List.of(appdata.settings['blockedWords'] as List);
      final earlyCallbacks = callbacks;
      final earlyMessages = List.of(messages);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, earlier, appdata.saveData(false)]),
      );
      await tester.pumpAndSettle();
      expect(before, ['old', 'old']);
      expect(earlyCallbacks, 0);
      expect(earlyMessages, isEmpty);
      final saved = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings'];
      expect(saved['blockedWords'], ['earlier', 'old', 'old', 'alpha']);
      expect(saved['blockedCommentWords'], ['comment']);
      expect(saved['extension'], {'keep': true});
      expect(callbacks, 1);
      expect(messages, ['Blocked']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'malformed keyword editing repairs only comics and survives JSON reload',
    (tester) async {
      appdata.settings['blockedWords'] = ['old', 12, null, 'old'];
      appdata.settings['blockedCommentWords'] = ['comment', 12, null];
      await open(tester, () {});
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await _flush(tester, appdata.saveData(false));
      await tester.pumpAndSettle();
      appdata.settings['blockedWords'] = ['discard this in-memory value'];
      await _flush(tester, appdata.loadDataForTesting(root.path));
      final restored = appdata;
      expect(restored.settings['blockedWords'], ['old', 'old', 'alpha']);
      expect(restored.settings['blockedCommentWords'], ['comment', 12, null]);
      expect(restored.settings['extension'], {'keep': true});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
