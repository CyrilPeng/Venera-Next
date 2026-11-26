import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/reader/image_save.dart';
import 'package:venera_next/features/settings/reader_image_save.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selector = MethodChannel('plugins.flutter.io/file_selector');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory output;
  late BuildContext owner;
  late SelectionTaskRegistry registry;
  late int dialogs;

  Widget app({Widget? body}) => MaterialApp(
    builder: (_, child) =>
        SelectionTasksScope(registry: registry, child: child!),
    home: Builder(
      builder: (context) {
        owner = context;
        return Scaffold(body: body);
      },
    ),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('reader-save-directory-');
    output = Directory('${root.path}/漫画')..createSync();
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    App.dataPath = (Directory('${root.path}/data')..createSync()).path;
    appdata.settings[ImageSavePreferences.directory.key] = null;
    appdata.settings['language'] = 'en-US';
    registry = SelectionTaskRegistry();
    dialogs = 0;
    messenger.setMockMethodCallHandler(selector, (_) async {
      dialogs++;
      return null;
    });
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });
  tearDown(() async {
    await registry.closeAndWait();
    messenger.setMockMethodCallHandler(selector, null);
    appdata.settings[ImageSavePreferences.directory.key] = null;
    root.deleteSync(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    await tester.pump();
    for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(condition(), isTrue);
  }

  testWidgets(
    'configured directory saves original bytes without repeated pickers',
    (tester) async {
      appdata.settings[ImageSavePreferences.directory.key] = output.path;
      await tester.pumpWidget(app());
      await tester.runAsync(() async {
        for (var i = 1; i <= 2; i++) {
          expect(
            await saveReaderImageForWindow(
              owner,
              data: Uint8List.fromList([255, 216, i, 255, 217]),
              filename: '漫画_EP1_P$i.jpg',
            ),
            isTrue,
          );
          expect(File('${output.path}/漫画_EP1_P$i.jpg').readAsBytesSync(), [
            255,
            216,
            i,
            255,
            217,
          ]);
        }
      });
      expect(dialogs, 0);
      expect(Directory(App.cachePath).listSync(), isEmpty);
    },
  );

  testWidgets('save as uses its own picker and keeps the configured folder', (
    tester,
  ) async {
    appdata.settings[ImageSavePreferences.directory.key] = output.path;
    final elsewhere = File('${root.path}/elsewhere.jpg');
    messenger.setMockMethodCallHandler(selector, (call) async {
      dialogs++;
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], '漫画_EP2_P7.jpg');
      return elsewhere.path;
    });
    await tester.pumpWidget(app());
    await tester.runAsync(() async {
      expect(
        await saveReaderImageForWindow(
          owner,
          data: Uint8List.fromList([7, 8]),
          filename: '漫画_EP2_P7.jpg',
          chooseLocation: true,
        ),
        isTrue,
      );
    });
    expect(dialogs, 1);
    expect(elsewhere.readAsBytesSync(), [7, 8]);
    expect(output.listSync(), isEmpty);
    expect(appdata.settings[ImageSavePreferences.directory.key], output.path);
  });

  testWidgets(
    'lost folder can be replaced while retaining the original image',
    (tester) async {
      appdata.settings[ImageSavePreferences.directory.key] =
          '${root.path}/removed';
      messenger.setMockMethodCallHandler(selector, (call) async {
        dialogs++;
        expect(call.method, 'getDirectoryPath');
        return output.path;
      });
      await tester.pumpWidget(app());
      late Future<bool> saving;
      await tester.runAsync(() async {
        saving = saveReaderImageForWindow(
          owner,
          data: Uint8List.fromList([3, 4]),
          filename: '漫画_EP3_P4.jpg',
        );
      });
      await waitFor(
        tester,
        () =>
            find.text('Image save directory unavailable').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Choose folder'));
      await tester.runAsync(() async {
        expect(await saving, isTrue);
      });
      await tester.pumpAndSettle();
      expect(File('${output.path}/漫画_EP3_P4.jpg').readAsBytesSync(), [3, 4]);
      expect(dialogs, 1);
      final stored =
          jsonDecode(File('${App.dataPath}/appdata.json').readAsStringSync())
              as Map;
      expect(
        stored['settings'][ImageSavePreferences.directory.key],
        output.path,
      );
      expect(Directory(App.cachePath).listSync(), isEmpty);
    },
  );

  testWidgets('closing the host dismisses only its recovery dialog', (
    tester,
  ) async {
    appdata.settings[ImageSavePreferences.directory.key] =
        '${root.path}/removed';
    await tester.pumpWidget(app());
    late Future<bool> saving;
    await tester.runAsync(() async {
      saving = saveReaderImageForWindow(
        owner,
        data: Uint8List.fromList([2]),
        filename: 'page.jpg',
      );
    });
    await waitFor(
      tester,
      () => find.text('Image save directory unavailable').evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      await registry.closeAndWait();
      expect(await saving, isFalse);
    });
    await tester.pumpAndSettle();
    expect(find.text('Image save directory unavailable'), findsNothing);
    expect(output.listSync(), isEmpty);
    expect(Directory(App.cachePath).listSync(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'settings persist a device folder and can restore asking every time',
    (tester) async {
      messenger.setMockMethodCallHandler(selector, (call) async {
        expect(call.method, 'getDirectoryPath');
        return output.path;
      });
      await tester.pumpWidget(app(body: const ReaderImageSaveSetting()));
      await tester.tap(find.text('Choose folder'));
      await waitFor(
        tester,
        () =>
            appdata.settings[ImageSavePreferences.directory.key] ==
                output.path &&
            tester
                    .widget<TextButton>(
                      find.widgetWithText(TextButton, 'Ask every time'),
                    )
                    .onPressed !=
                null,
      );
      await tester.pumpAndSettle();
      expect(find.text(output.path), findsOneWidget);
      await tester.tap(find.text('Ask every time'));
      await waitFor(
        tester,
        () =>
            appdata.settings[ImageSavePreferences.directory.key] == null &&
            tester
                    .widget<TextButton>(
                      find.widgetWithText(TextButton, 'Choose folder'),
                    )
                    .onPressed !=
                null,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await registry.closeAndWait();
      });
      final stored =
          jsonDecode(File('${App.dataPath}/appdata.json').readAsStringSync())
              as Map;
      expect(stored['settings'][ImageSavePreferences.directory.key], isNull);
    },
  );
}
