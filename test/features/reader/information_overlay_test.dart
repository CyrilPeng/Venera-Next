import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/platform_effects_controller.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/features/reader/progress_navigation.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/shell_data.dart';
import 'package:venera_next/features/reader/status_info.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const battery = MethodChannel('dev.fluttercommunity.plus/battery');
  setUpAll(() async {
    final path = Platform.environment['INFORMATION_QA_FONT'];
    if (path == null) return;
    await (FontLoader(
      'InformationQA',
    )..addFont(File(path).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(battery, null),
  );

  for (final scenario in [
    (size: const Size(375, 667), scale: 1.0, dark: false),
    (size: const Size(375, 667), scale: 3.2, dark: true),
    (size: const Size(667, 375), scale: 1.0, dark: true),
    (size: const Size(667, 375), scale: 3.2, dark: false),
    (size: const Size(1024, 768), scale: 2.0, dark: false),
    (size: const Size(320, 568), scale: 3.2, dark: true),
  ]) {
    testWidgets('information stays readable inside safe area $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var batteryReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(battery, (call) async {
            if (call.method == 'getBatteryLevel') {
              batteryReads++;
              return 85;
            }
            return 'discharging';
          });
      final f = _Fixture();
      try {
        Future<void> mount() async {
          await tester.pumpWidget(f.build(scenario.scale, scenario.dark));
          await tester.pump();
        }

        await mount();
        final status = tester.state(find.byType(ReaderStatusInfo));
        void checkBounds() {
          final safe = Rect.fromLTRB(
            f.padding.left,
            f.padding.top,
            scenario.size.width - f.padding.right,
            scenario.size.height - f.padding.bottom,
          );
          for (final type in [ReaderPageInfo, ReaderStatusInfo]) {
            final bounds = tester.getRect(find.byType(type));
            expect(bounds.left, greaterThanOrEqualTo(safe.left));
            expect(bounds.right, lessThanOrEqualTo(safe.right));
            expect(bounds.top, greaterThanOrEqualTo(safe.top));
            expect(bounds.bottom, lessThanOrEqualTo(safe.bottom));
          }
          expect(
            tester
                .getRect(find.byType(ReaderPageInfo))
                .overlaps(tester.getRect(find.byType(ReaderStatusInfo))),
            isFalse,
          );
          expect(tester.takeException(), isNull);
          for (final element in find.text('4/12').evaluate()) {
            expect(
              (element.findRenderObject()! as RenderParagraph)
                  .didExceedMaxLines,
              isFalse,
            );
          }
          expect(find.text('4/12'), findsNWidgets(2));
        }

        checkBounds();
        expect(find.text('85%'), findsNWidgets(2));
        for (final type in [ReaderPageInfo, ReaderStatusInfo]) {
          await tester.tapAt(tester.getCenter(find.byType(type)));
        }
        expect(
          f.taps,
          2,
          reason: 'Information must not intercept reading taps.',
        );
        final directory = Platform.environment['INFORMATION_QA_DIR'];
        if (directory != null) {
          await tester.runAsync(() async {
            final boundary =
                f.repaint.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final frame = await boundary.toImage();
            try {
              final data = await frame.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$directory/${scenario.size.width.toInt()}-${scenario.dark ? 'dark' : 'light'}-${scenario.scale}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              frame.dispose();
            }
          });
        }
        f.padding = const EdgeInsets.fromLTRB(40, 24, 16, 48);
        await mount();
        checkBounds();
        expect(tester.state(find.byType(ReaderStatusInfo)), same(status));
        f.showPage = false;
        await mount();
        expect(find.byType(ReaderPageInfo), findsNothing);
        expect(tester.state(find.byType(ReaderStatusInfo)), same(status));
        expect(
          batteryReads,
          1,
          reason: 'Changing page visibility must not replace polling.',
        );
        f.showPage = true;
        f.showStatus = false;
        await mount();
        expect(find.byType(ReaderStatusInfo), findsNothing);
        expect(find.byType(ReaderPageInfo), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        expect(batteryReads, 1);
        f.showPage = false;
        await mount();
        expect(find.byType(ReaderPageInfo), findsNothing);
        f.showPage = true;
        f.showStatus = true;
        f.comments = true;
        await mount();
        expect(find.byType(ReaderPageInfo), findsNothing);
        expect(find.byType(ReaderStatusInfo), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await f.work.dispose();
        f.favorites.dispose();
      }
    });
  }

  testWidgets('long page counts wrap without losing digits', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 140,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(3.2)),
              child: const ReaderPageInfo(
                chapterTitle: 'A long chapter',
                page: 9999,
                maxPage: 10000,
              ),
            ),
          ),
        ),
      ),
    );
    for (final element in find.text('9999/10000').evaluate()) {
      final paragraph = element.findRenderObject()! as RenderParagraph;
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.size.width, lessThanOrEqualTo(140));
      expect(paragraph.size.height, greaterThan(14 * 3.2));
    }
    expect(find.text('9999/10000'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'outlined information exposes each text once to assistive technology',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: [
                const ReaderPageInfo(
                  chapterTitle: 'Chapter 2',
                  page: 4,
                  maxPage: 12,
                ),
                ReaderStatusInfo(
                  now: () => DateTime(2026, 10, 7, 12, 34),
                  readBattery: () async =>
                      const ReaderBatterySnapshot(85, charging: false),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        final labels = <String>[];
        void visit(SemanticsNode node) {
          labels.add(node.getSemanticsData().label);
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(
          tester
              .binding
              .renderViews
              .single
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!,
        );
        final all = labels.join('\n');
        for (final text in ['Chapter 2 : 4/12', '12:34', '85%']) {
          expect(
            RegExp(RegExp.escape(text)).allMatches(all),
            hasLength(1),
            reason: all,
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      }
    },
  );
}

class _Fixture {
  final work = ImageWork();
  final favorites = ChangeNotifier();
  final repaint = GlobalKey();
  final progressIdentity = Object();
  var padding = const EdgeInsets.fromLTRB(16, 24, 12, 20);
  bool showPage = true, showStatus = true, comments = false;
  int taps = 0;

  Widget build(double scale, bool dark) => MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      fontFamily: Platform.environment['INFORMATION_QA_FONT'] == null
          ? null
          : 'InformationQA',
    ),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: padding,
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: RepaintBoundary(
          key: repaint,
          child: Scaffold(
            body: SizedBox.expand(
              child: ReaderScaffold(
                data: ReaderShellData(
                  comicId: 'book',
                  sourceKey: 'local',
                  title: 'Book',
                  chapterTitle: 'A very long chapter title',
                  hasChapters: true,
                  vertical: true,
                  gallery: false,
                  animating: false,
                  onCommentsPage: comments,
                  swipeToCollect: false,
                  preferences: ReaderSettings.resolve(
                    global: {
                      'showPageNumberInReader': showPage,
                      'enableClockAndBatteryInfoInReader': showStatus,
                    },
                  ),
                  automaticReading: AutoReadingStatus.stopped,
                ),
                progress: ReaderProgressRequest(
                  identity: progressIdentity,
                  page: 4,
                  maxPage: 12,
                  chapter: 2,
                  maxChapter: 3,
                  reversed: false,
                  isCurrent: () => true,
                  toPage: (_, {animated = true}) => true,
                  toChapter: (_) => true,
                ),
                onExit: () async {},
                onFullscreen: null,
                onToggleAutomaticReading: () => false,
                acquireSidebarPause: () => () {},
                readImagePickContext: () => null,
                imageWork: work,
                orientation: ReaderOrientation.system,
                onRotate: null,
                onSystemUiChanged: (_) {},
                createChapterMenu: () => null,
                favoriteChanges: favorites,
                createFavoriteQuery: () => null,
                createImageFavorite: () => null,
                createImageExport: () => null,
                createSettings: () => null,
                createChapterComments: () => null,
                chapterNavigation: null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const ColoredBox(color: Color(0xff758473)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
