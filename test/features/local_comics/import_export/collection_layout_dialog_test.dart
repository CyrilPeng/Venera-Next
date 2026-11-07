import 'dart:async';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? oldLanguage;
  late WindowSelectionTask task;
  late Future<bool?> result;
  late GlobalKey<NavigatorState> navigator;
  late GlobalKey preview;
  const enclosing = 'Collection with a deliberately long original folder name';
  final titles = List.generate(
    8,
    (index) => 'Book ${index + 1} - original title',
  );

  setUpAll(() async {
    final font = Platform.environment['COLLECTION_QA_FONT'];
    if (font != null) {
      await (FontLoader('CollectionPreview')..addFont(
            File(
              font,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
    final icons = Platform.environment['COLLECTION_QA_ICONS'];
    if (icons != null) {
      await (FontLoader('MaterialIcons')..addFont(
            File(
              icons,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
  });

  setUp(() {
    oldLanguage = appdata.settings['language'];
    navigator = GlobalKey<NavigatorState>();
    preview = GlobalKey();
  });
  tearDown(() => appdata.settings['language'] = oldLanguage);

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool reducedMotion = false,
    String language = 'en-US',
  }) async {
    appdata.settings['language'] = language;
    await AppTranslation.init();
    await tester.pumpWidget(
      RepaintBoundary(
        key: preview,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(
            brightness: brightness,
            fontFamily: 'CollectionPreview',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reducedMotion,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  task = WindowSelectionTask(context);
                  result = task.run(
                    (_) => ImportComicPresentation.forTask(task)
                        .chooseCollectionLayout(
                          enclosingComic: enclosing,
                          comicTitles: titles,
                        ),
                  );
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String filename) async {
    final directory = Platform.environment['COLLECTION_QA_DIRECTORY'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$filename');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 812), const Size(812, 375)]) {
      testWidgets(
        'large-text ${brightness.name} $size confirms a layout without overflow',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await show(
            tester,
            brightness: brightness,
            textScale: 2,
            reducedMotion: true,
            language: 'zh-CN',
          );
          expect(find.text('Choose collection layout'.tl), findsOneWidget);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          expect(tester.takeException(), isNull);
          await screenshot(
            tester,
            'collection-${brightness.name}-${size.width.toInt()}.png',
          );
          final separate = find.text(
            'Separate comics (@a)'.tlParams({'a': titles.length}),
          );
          await tester.ensureVisible(separate);
          await tester.tap(separate);
          await tester.pumpAndSettle();
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNotNull,
          );
          await tester.tap(find.text('Import'.tl));
          await tester.pumpAndSettle();
          expect(await result, isTrue);
          expect(find.text('Choose'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'one comic preserves chapters and keyboard cancellation returns no choice',
    (tester) async {
      await show(tester);
      await tester.ensureVisible(find.text('One comic with chapters'.tl));
      await tester.tap(find.text('One comic with chapters'.tl));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'.tl));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancellation removes only its own covered dialog', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(
      find.text('Separate comics (@a)'.tlParams({'a': titles.length})),
    );
    await tester.pumpAndSettle();
    final submit = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Successor')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    submit();
    await tester.pump();
    expect(find.text('Successor'), findsOneWidget);
    task.cancel();
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('Successor'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Choose collection layout'.tl), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unmount drains the original dialog and does not adopt a new root',
    (tester) async {
      await show(tester);
      final old = ImportComicPresentation.forTask(task);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await result, isNull);
      await show(tester);
      expect(
        await old.chooseCollectionLayout(
          enclosingComic: enclosing,
          comicTitles: titles,
        ),
        isNull,
      );
      expect(find.text('Choose collection layout'.tl), findsOneWidget);
      await tester.tap(find.text('Cancel'.tl));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test('headless presentation never guesses an ambiguous layout', () async {
    expect(
      await const ImportComicPresentation().chooseCollectionLayout(
        enclosingComic: enclosing,
        comicTitles: titles,
      ),
      isNull,
    );
  });
}
