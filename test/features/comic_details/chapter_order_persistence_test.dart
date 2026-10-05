import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/comic_details/chapters.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

final _gates = <Completer<void>>[];

Directory _prepare(WidgetTester tester) {
  final root = Directory.systemTemp.createTempSync('chapter-order-');
  final previousPath = App.dataPath;
  final previous = Map<String, dynamic>.from(
    appdata.toJson()['settings'] as Map,
  );
  App.dataPath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['reverseChapterOrder'] = false;
  registerShowMessageHandler((_, _) {});
  addTearDown(() async {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
    await tester.pumpWidget(const SizedBox());
    await _flush(tester, appdata.saveData(false));
    previous.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = previousPath;
    root.deleteSync(recursive: true);
  });
  return root;
}

Future<void> _flush(WidgetTester tester, Future<void> work) async {
  var done = false;
  Object? error;
  work.then<void>(
    (_) => done = true,
    onError: (Object e) {
      error = e;
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
}

const _flat = ComicChapters({'one': 'First chapter', 'two': 'Second chapter'});
const _grouped = ComicChapters.grouped({
  'Volume A': {'one': 'First chapter', 'two': 'Second chapter'},
  'Volume B': {'one': 'Third chapter'},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  for (final grouped in [false, true]) {
    testWidgets(
      'chapter order previews and detached window waits: grouped=$grouped',
      (tester) async {
        final root = _prepare(tester);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            null,
          ),
        );
        var showing = true;
        var exits = 0;
        late StateSetter update;
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowFrame(
              child!,
              onExit: () async {
                exits++;
              },
            ),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return CustomScrollView(
                    slivers: [
                      const SliverToBoxAdapter(child: SizedBox(height: 48)),
                      if (showing)
                        ComicChaptersView(
                          chapters: grouped ? _grouped : _flat,
                          readChapter: selected.add,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        final owner = tester.state<SettingsSaveState>(
          find.byType(ComicChaptersView),
        );
        final gate = Completer<void>();
        _gates.add(gate);
        final exclusive = AppDataOperations.instance.run(() => gate.future);
        await tester.tap(find.text('Descending'));
        await tester.pump();
        expect(
          tester.getTopLeft(find.text('Second chapter')).dx,
          lessThan(tester.getTopLeft(find.text('First chapter')).dx),
        );
        await tester.tap(find.text('Second chapter'));
        expect(selected, [2]);
        expect(appdata.settings['reverseChapterOrder'], isFalse);
        update(() => showing = false);
        await tester.pump();
        (tester.state(find.byType(WindowFrame)) as WindowListener)
            .onWindowClose();
        await tester.pump();
        expect(exits, 0);
        gate.complete();
        await _flush(
          tester,
          Future.wait([exclusive, owner.waitForSettingsSave()]),
        );
        for (var i = 0; i < 20 && exits == 0; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(exits, 1);
        final saved =
            jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
                as Map;
        expect((saved['settings'] as Map)['reverseChapterOrder'], isTrue);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'chapter save retry preserves latest choice and fits narrow large text',
    (tester) async {
      final root = _prepare(tester);
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ComicChaptersView(chapters: _flat, readChapter: (_) {}),
              ],
            ),
          ),
        ),
      );
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      await tester.tap(find.text('Descending'));
      final owner = tester.state<SettingsSaveState>(
        find.byType(ComicChaptersView),
      );
      await _flush(
        tester,
        owner.waitForSettingsSave().catchError((Object _) {}),
      );
      expect(find.text('Retry'), findsOneWidget);
      blocked.deleteSync();
      await tester.tap(find.text('Retry'));
      await _flush(tester, owner.waitForSettingsSave());
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'grouped chapters retain selected group and replace tab controllers',
    (tester) async {
      _prepare(tester);
      final selected = <int>[];
      Future<void> show(ComicChapters chapters) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ComicChaptersView(
                  chapters: chapters,
                  readChapter: selected.add,
                ),
              ],
            ),
          ),
        ),
      );
      await show(_grouped);
      await tester.tap(find.text('Volume B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Third chapter'));
      expect(selected, [3]);
      await show(
        const ComicChapters.grouped({
          'Volume B': {'one': 'Third chapter'},
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Third chapter'));
      expect(selected, [3, 1]);
      await show(const ComicChapters.grouped({}));
      await tester.pumpAndSettle();
      await show(_grouped);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
