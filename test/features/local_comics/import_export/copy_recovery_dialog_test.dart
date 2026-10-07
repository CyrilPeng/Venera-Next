import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/local_comics/import_export/import_presentation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['COPY_RECOVERY_QA_FONT'];
    if (font == null) return;
    await (FontLoader(
      'RecoveryQA',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
  });
  setUp(() async {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    await AppTranslation.init();
    addTearDown(() => appdata.settings['language'] = language);
  });

  Future<ImportComicPresentation> host(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    GlobalKey? boundary,
  }) async {
    late BuildContext original;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            fontFamily:
                Platform.environment.containsKey('COPY_RECOVERY_QA_FONT')
                ? 'RecoveryQA'
                : null,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              original = context;
              return const Scaffold(body: Text('Local comics'));
            },
          ),
        ),
      ),
    );
    return ImportComicPresentation.forTask(WindowSelectionTask(original));
  }

  for (final localOnly in [false, true]) {
    testWidgets(
      'requires an explicit recovery destination; localOnly=$localOnly',
      (tester) async {
        final presentation = await host(tester);
        final decision = presentation.chooseCopyRecovery(
          title: 'Original title',
          previousFolder: 'Old folder',
          folders: ['Current folder'],
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.tap(
          find.text(localOnly ? 'Local library only'.tl : 'Current folder'),
        );
        await tester.pump();
        await tester.tap(find.text('Restore'.tl));
        await tester.pumpAndSettle();
        expect((await decision)!.folder, localOnly ? isNull : 'Current folder');
        expect(find.text('Local comics'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('keyboard selection and Escape retain explicit cancellation', (
    tester,
  ) async {
    final presentation = await host(tester);
    final decision = presentation.chooseCopyRecovery(
      title: 'Original title',
      previousFolder: 'Old folder',
      folders: ['First', 'Second'],
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await decision, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unmounted owner releases the dialog and cannot adopt a new root',
    (tester) async {
      final presentation = await host(tester);
      final decision = presentation.chooseCopyRecovery(
        title: 'Old copy',
        previousFolder: 'Old folder',
        folders: ['Current folder'],
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(await decision, isNull);
      await host(tester);
      expect(
        await presentation.chooseCopyRecovery(
          title: 'Late copy',
          previousFolder: 'Old folder',
          folders: [],
        ),
        isNull,
      );
      expect(find.text('Late copy'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final spec in [
    (const Size(375, 667), 1.0, Brightness.light, 'en-US'),
    (const Size(667, 375), 3.2, Brightness.dark, 'zh-CN'),
    (const Size(1024, 768), 2.0, Brightness.light, 'zh-CN'),
  ]) {
    testWidgets('recovery is scrollable at ${spec.$1}, scale ${spec.$2}', (
      tester,
    ) async {
      appdata.settings['language'] = spec.$4;
      tester.view.physicalSize = spec.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      final presentation = await host(
        tester,
        scale: spec.$2,
        brightness: spec.$3,
        boundary: boundary,
      );
      final folders = List.generate(
        12,
        (i) => 'Collection $i with a longer descriptive name',
      );
      final decision = presentation.chooseCopyRecovery(
        title: 'A comic with an unusually long original title',
        previousFolder: 'An older collection with a long name',
        folders: folders,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Restore'.tl), findsOneWidget);
      Future<void> capture(String state) async {
        final output = Platform.environment['COPY_RECOVERY_QA_DIRECTORY'];
        if (output != null) {
          final shadows = debugDisableShadows;
          debugDisableShadows = false;
          tester.element(find.byType(MaterialApp)).markNeedsBuild();
          await tester.pumpAndSettle();
          try {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(output).create(recursive: true);
              await File(
                '$output/recovery-${spec.$1.width.toInt()}-${spec.$1.height.toInt()}-$state.png',
              ).writeAsBytes(png!.buffer.asUint8List());
              image.dispose();
            });
          } finally {
            debugDisableShadows = shadows;
          }
        }
      }

      await capture('initial');
      // A multiline label may be taller than the scroll viewport at large text
      // sizes. Bring the actual radio control into view before tapping it.
      final lastRadio = find.byType(Radio<int>).last;
      await tester.ensureVisible(lastRadio);
      await tester.pumpAndSettle();
      expect(lastRadio.hitTestable(), findsOneWidget);
      await tester.tap(lastRadio);
      await tester.pump();
      final restoreRect = tester.getRect(find.byType(FilledButton));
      expect(restoreRect.top, greaterThanOrEqualTo(0));
      expect(restoreRect.bottom, lessThanOrEqualTo(spec.$1.height));
      expect(restoreRect.height, greaterThanOrEqualTo(48));
      await capture('selected');
      await tester.tap(find.text('Restore'.tl));
      await tester.pumpAndSettle();
      expect((await decision)!.folder, folders.last);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
