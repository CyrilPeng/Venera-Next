import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/reader/platform_effects_controller.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/features/reader/progress_navigation.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/shell_data.dart';
import 'package:venera_next/features/reader/top_bar.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_settings.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['SHELL_INPUTS_QA_FONT'];
    if (font == null) return;
    await (FontLoader(
      'ShellQA',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  for (final scenario in [
    (size: const Size(375, 667), scale: 1.0, brightness: Brightness.light),
    (size: const Size(667, 375), scale: 3.2, brightness: Brightness.dark),
    (size: const Size(1024, 768), scale: 2.0, brightness: Brightness.light),
  ]) {
    testWidgets('shell renders from explicit input at ${scenario.size}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'en-US';
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      final work = ImageWork();
      final favorites = ChangeNotifier();
      final shell = GlobalKey<ReaderScaffoldState>();
      final repaint = GlobalKey();
      final calls = <String>[];
      final semantics = tester.ensureSemantics();
      var active = false;
      var reducedMotion = true;
      var chapter = 2;
      var comments = false;
      var identity = Object();
      ReaderShellData data() => ReaderShellData(
        comicId: 'synthetic',
        sourceKey: 'local',
        title: 'An illustrated journey through the mountains',
        chapterTitle: 'Chapter $chapter: a new beginning',
        hasChapters: true,
        vertical: false,
        gallery: true,
        animating: false,
        onCommentsPage: comments,
        swipeToCollect: false,
        preferences: ReaderSettings.resolve(
          global: {
            'readerBrightnessEnabled': true,
            'readerBrightness': 60,
            'showPageNumberInReader': true,
            'enableClockAndBatteryInfoInReader': false,
          },
        ),
        automaticReading: active
            ? AutoReadingStatus.running
            : AutoReadingStatus.stopped,
      );
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: scenario.brightness,
            fontFamily: Platform.environment['SHELL_INPUTS_QA_FONT'] == null
                ? null
                : 'ShellQA',
          ),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scenario.scale),
                disableAnimations: reducedMotion,
                padding: const EdgeInsets.fromLTRB(8, 24, 8, 20),
              ),
              child: RepaintBoundary(
                key: repaint,
                child: Scaffold(
                  body: SizedBox.expand(
                    child: ReaderScaffold(
                      key: shell,
                      data: data(),
                      progress: ReaderProgressRequest(
                        identity: identity,
                        page: comments ? 13 : 3,
                        maxPage: 12,
                        chapter: chapter,
                        maxChapter: 5,
                        reversed: false,
                        isCurrent: () => true,
                        toPage: (page, {animated = true}) {
                          calls.add('page $page');
                          return true;
                        },
                        toChapter: (chapter) {
                          calls.add('chapter $chapter');
                          return true;
                        },
                      ),
                      imageWork: work,
                      favoriteChanges: favorites,
                      orientation: ReaderOrientation.system,
                      onRotate: () => calls.add('rotate'),
                      onExit: () async => calls.add('exit'),
                      onFullscreen: null,
                      onToggleAutomaticReading: () {
                        calls.add('auto');
                        return active = !active;
                      },
                      acquireSidebarPause: () => () {},
                      readImagePickContext: () => null,
                      onSystemUiChanged: (open) => calls.add('menu $open'),
                      createChapterMenu: () => null,
                      createFavoriteQuery: () => null,
                      createImageFavorite: () => null,
                      createImageExport: () => null,
                      createSettings: () => null,
                      createChapterComments: () => null,
                      chapterNavigation: null,
                      child: const ColoredBox(
                        color: Color(0xff758473),
                        child: Center(child: Text('Synthetic reading content')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await mount();
      final rotationFocus = Focus.of(
        tester.element(find.byIcon(Icons.screen_rotation)),
      );
      expect(rotationFocus.canRequestFocus, isFalse);
      expect(find.bySemanticsLabel('Page'), findsNothing);
      shell.currentState!.openOrClose();
      await tester.pump();
      expect(
        tester.getRect(find.byType(ReaderBottomBar)).bottom,
        scenario.size.height,
        reason: 'Reduced motion positions both bars immediately.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(ReaderBottomBar),
          matching: find.byTooltip('Previous chapter'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ReaderBottomBar),
          matching: find.byTooltip('Next chapter'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ReaderTopBar>(find.byType(ReaderTopBar)).chapterTitle,
        'Chapter 2: a new beginning',
      );
      final top = tester.getRect(find.byType(ReaderTopBar));
      expect(tester.getSize(find.byType(ReaderScaffold)), scenario.size);
      expect(top.top, 0);
      for (final label in [
        'An illustrated journey through the mountains',
        'Chapter 2: a new beginning',
      ]) {
        final bounds = tester.getRect(find.text(label));
        expect(bounds.top, greaterThanOrEqualTo(top.top + 24));
        expect(bounds.bottom, lessThanOrEqualTo(top.bottom));
      }
      expect(
        tester.getRect(find.byIcon(Icons.share)).bottom,
        lessThanOrEqualTo(scenario.size.height - 20),
      );
      expect(
        tester
            .widget<ReaderBrightnessOverlay>(
              find.byType(ReaderBrightnessOverlay),
            )
            .brightness,
        60,
      );
      Focus.of(tester.element(find.byIcon(Icons.first_page))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final output = Platform.environment['SHELL_INPUTS_QA_DIR'];
      if (output != null) {
        final previousShadows = debugDisableShadows;
        final boundary =
            repaint.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        try {
          // Widget tests draw black outlines instead of real elevation shadows.
          debugDisableShadows = false;
          boundary.markNeedsPaint();
          await tester.pump();
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(output).create(recursive: true);
            await File(
              '$output/${scenario.size.width.toInt()}-${scenario.brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        } finally {
          debugDisableShadows = previousShadows;
          boundary.markNeedsPaint();
          await tester.pump();
        }
      }
      await tester.tap(find.byTooltip('Reader brightness'));
      await tester.pump();
      expect(
        tester.getRect(find.byType(ReaderBrightnessPanel)).bottom,
        scenario.size.height - ReaderBottomBar.height - 20 - 12,
      );
      await tester.tap(find.byTooltip('Reader brightness'));
      await tester.pump();
      Focus.of(
        tester.element(find.byIcon(Icons.screen_rotation)),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, contains('rotate'));
      await tester.tap(find.byIcon(Icons.play_circle_outline));
      expect(active, isTrue);
      expect(shell.currentState!.isOpen, isFalse);
      await mount();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(rotationFocus.canRequestFocus, isFalse);
      expect(find.bySemanticsLabel('Page'), findsNothing);
      reducedMotion = false;
      await mount();
      shell.currentState!.openOrClose();
      await tester.pumpAndSettle();
      rotationFocus.requestFocus();
      await tester.pump();
      final rotationPoint = tester.getCenter(
        find.byIcon(Icons.screen_rotation),
      );
      shell.currentState!.openOrClose();
      await tester.pump();
      expect(
        tester.getRect(find.byType(ReaderBottomBar)).bottom,
        scenario.size.height,
      );
      expect(rotationFocus.hasFocus, isFalse);
      expect(find.bySemanticsLabel('Page'), findsNothing);
      await tester.tapAt(rotationPoint);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls.where((call) => call == 'rotate'), hasLength(1));
      await tester.pumpAndSettle();
      reducedMotion = true;
      chapter = 3;
      comments = true;
      identity = Object();
      await mount();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderTopBar>(find.byType(ReaderTopBar)).chapterTitle,
        'Chapter 3: a new beginning',
      );
      expect(find.byType(ReaderBrightnessOverlay), findsNothing);
      expect(find.byType(ReaderPageInfo), findsNothing);
      expect(
        tester.widget<ReaderBottomBar>(find.byType(ReaderBottomBar)).label,
        'E3 : P12',
      );
      await tester.pumpWidget(const SizedBox());
      await work.dispose();
      favorites.dispose();
      semantics.dispose();
    });
  }
}
