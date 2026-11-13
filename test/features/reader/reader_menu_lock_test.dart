import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/features/reader/gesture_request.dart';
import 'package:venera_next/features/reader/platform_effects_controller.dart';
import 'package:venera_next/features/reader/progress_navigation.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/shell_data.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_settings.dart';

import '../../support/ui_regression_capture.dart';

class _Viewport implements ReaderImageViewController {
  final calls = <String>[];

  @override
  bool handleOnTap(Offset point) => false;

  @override
  void handleDoubleTap(Offset point) => calls.add('double tap');

  @override
  void handleLongPressDown(Offset point) => calls.add('zoom down');

  @override
  void handleLongPressUp(Offset point) => calls.add('zoom up');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  final work = ImageWork();
  final favorites = ChangeNotifier();
  final changes = ValueNotifier(0);
  final shellKey = GlobalKey<ReaderScaffoldState>();
  final repaint = GlobalKey();
  final scroll = ScrollController();
  final viewport = _Viewport();
  final calls = <String>[];
  final padding = const EdgeInsets.fromLTRB(16, 24, 12, 20);
  String comicId = 'book', sourceKey = 'local';
  bool gallery = true, doubleTap = false, tv = false;
  int chapter = 1, commentsRequests = 0;
  double scale = 1;
  Brightness brightness = Brightness.light;

  ReaderScaffoldState get shell => shellKey.currentState!;

  ReaderSettings get preferences => ReaderSettings.resolve(
    global: {
      'enableDoubleTapToZoom': doubleTap,
      'enableTapToTurnPages': true,
      'longPressAction': 'zoom',
      'showPageNumberInReader': false,
      'enableClockAndBatteryInfoInReader': false,
    },
  );

  ReaderGestureRequest request() {
    final target = (comicId, sourceKey, chapter);
    return ReaderGestureRequest(
      identity: target,
      isCurrent: () =>
          shellKey.currentState != null &&
          target == (comicId, sourceKey, chapter),
      viewport: viewport,
      preferences: preferences,
      vertical: !gallery,
      reversed: false,
      onCommentsPage: false,
      canUseImage: false,
      turnPage: (forward) => calls.add(forward ? 'next' : 'previous'),
      turnWheel: (forward) =>
          calls.add(forward ? 'wheel next' : 'wheel previous'),
      toggleAutomaticReading: () {},
      stopAutomaticReading: () {},
      acquirePause: () => () {},
      fullscreen: () {},
      exit: () async => calls.add('exit'),
    );
  }

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, fontFamily: uiRegressionFont),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: padding,
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: TvNavigation(
            enabled: tv,
            child: RepaintBoundary(
              key: repaint,
              child: Scaffold(
                body: SizedBox.expand(
                  child: ReaderScaffold(
                    key: shellKey,
                    data: ReaderShellData(
                      comicId: comicId,
                      sourceKey: sourceKey,
                      title: 'A quiet journey',
                      chapterTitle: 'Chapter $chapter',
                      hasChapters: true,
                      vertical: !gallery,
                      gallery: gallery,
                      animating: false,
                      onCommentsPage: false,
                      swipeToCollect: false,
                      preferences: preferences,
                      automaticReading: AutoReadingStatus.stopped,
                    ),
                    progress: ReaderProgressRequest(
                      identity: (comicId, sourceKey, chapter),
                      page: 2,
                      maxPage: 10,
                      chapter: chapter,
                      maxChapter: 5,
                      reversed: false,
                      isCurrent: () => true,
                      toPage: (_, {animated = true}) => true,
                      toChapter: (_) => true,
                    ),
                    onExit: () async => calls.add('exit'),
                    onFullscreen: null,
                    onToggleAutomaticReading: () => false,
                    acquireSidebarPause: () => () {},
                    readImagePickContext: () => null,
                    imageWork: work,
                    orientation: ReaderOrientation.system,
                    onRotate: null,
                    onSystemUiChanged: (open) => calls.add('menu $open'),
                    createChapterMenu: () {
                      calls.add('chapters');
                      return null;
                    },
                    favoriteChanges: favorites,
                    createFavoriteQuery: () => null,
                    createImageFavorite: () => null,
                    createImageExport: () => null,
                    createSettings: () {
                      calls.add('settings');
                      return null;
                    },
                    createChapterComments: () {
                      commentsRequests++;
                      return null;
                    },
                    chapterNavigation: null,
                    onRemoteKey: (event) =>
                        calls.add('remote ${event.logicalKey}'),
                    child: Builder(
                      builder: (context) {
                        final owner = context
                            .findAncestorStateOfType<ReaderScaffoldState>()!;
                        return ReaderGestureDetector(
                          imageWork: work,
                          changes: changes,
                          createRequest: request,
                          onPortChanged: owner.onGesturePortChanged,
                          isMenuOpen: () => owner.isOpen,
                          isMenuLocked: () => owner.isMenuLocked,
                          toggleMenu: owner.openOrClose,
                          openSettings: owner.openSetting,
                          openChapters: owner.openChapterDrawer,
                          child: gallery
                              ? const ColoredBox(
                                  color: Color(0xff758473),
                                  child: Center(child: Text('Reading content')),
                                )
                              : SingleChildScrollView(
                                  controller: scroll,
                                  child: const SizedBox(
                                    height: 2400,
                                    child: ColoredBox(color: Color(0xff758473)),
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Offset center(WidgetTester tester) =>
      tester.getCenter(find.byType(ReaderScaffold));

  Future<void> lock(WidgetTester tester) async {
    shell.openOrClose();
    await tester.pumpAndSettle();
    expect(shell.isOpen, isTrue);
    await tester.tap(find.byKey(const ValueKey('reader-menu-lock')));
    await tester.pumpAndSettle();
    expect(shell.isMenuLocked, isTrue);
    expect(shell.isOpen, isFalse);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await work.dispose();
    favorites.dispose();
    changes.dispose();
    scroll.dispose();
  }
}

void main() {
  Object? previousLanguage;
  setUpAll(loadUiRegressionFonts);
  setUp(() {
    previousLanguage = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() => appdata.settings['language'] = previousLanguage);

  testWidgets('lock closes all menu entry points until an explicit unlock', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.lock(tester);
    f.calls.clear();
    final commentsRequests = f.commentsRequests;
    f.shell.openOrClose();
    f.shell.openSetting();
    f.shell.openChapterDrawer();
    f.shell.openChapterComments();
    expect(f.calls, isEmpty);
    expect(f.commentsRequests, commentsRequests);

    await tester.tapAt(f.center(tester));
    await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(f.shell.isOpen, isFalse);
    expect(find.text('Settings'), findsNothing);
    expect(f.calls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('reader-menu-unlock')));
    await tester.pumpAndSettle();
    expect(f.shell.isMenuLocked, isFalse);
    expect(f.shell.isOpen, isFalse);
    expect(f.calls, isEmpty);
    await tester.tapAt(f.center(tester));
    await tester.pumpAndSettle();
    expect(f.shell.isOpen, isTrue);
    expect(f.calls, ['menu true']);
    await f.dispose(tester);
  });

  testWidgets('locked reader keeps page taps and zoom gestures', (
    tester,
  ) async {
    final f = _Fixture()..doubleTap = true;
    await f.mount(tester);
    await f.lock(tester);
    f.calls.clear();
    final bounds = tester.getRect(find.byType(ReaderScaffold));
    await tester.tapAt(Offset(bounds.left + 20, bounds.center.dy));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(Offset(bounds.right - 80, bounds.center.dy));
    await tester.pump(const Duration(milliseconds: 220));
    expect(f.calls, ['previous', 'next']);

    await tester.tapAt(f.center(tester));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(f.center(tester));
    await tester.pump();
    expect(f.viewport.calls, ['double tap']);
    await tester.longPressAt(f.center(tester));
    await tester.pump();
    expect(f.viewport.calls, ['double tap', 'zoom down', 'zoom up']);
    expect(f.shell.isMenuLocked, isTrue);
    expect(f.shell.isOpen, isFalse);
    await f.dispose(tester);
  });

  testWidgets(
    'locked continuous reader scrolls and swiping the lock does not unlock',
    (tester) async {
      final f = _Fixture()..gallery = false;
      await f.mount(tester);
      await f.lock(tester);
      await tester.dragFrom(f.center(tester), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(f.scroll.offset, greaterThan(0));
      await tester.drag(
        find.byKey(const ValueKey('reader-menu-unlock')),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();
      expect(f.shell.isMenuLocked, isTrue);
      expect(f.shell.isOpen, isFalse);
      await f.dispose(tester);
    },
  );

  testWidgets(
    'locking and unlocking discard taps accepted before the transition',
    (tester) async {
      final f = _Fixture()..doubleTap = true;
      await f.mount(tester);
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 100));
      f.shell.lockMenu();
      f.shell.unlockMenu();
      await tester.pump(const Duration(milliseconds: 250));
      expect(f.shell.isOpen, isFalse);

      f.shell.lockMenu();
      await tester.pump();
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('reader-menu-unlock')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(f.shell.isMenuLocked, isFalse);
      expect(f.shell.isOpen, isFalse);
      await f.dispose(tester);
    },
  );

  testWidgets(
    'locking retires an existing context menu and unlocking restores it',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      f.shell.lockMenu();
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-menu-unlock')));
      await tester.pumpAndSettle();
      await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(f.calls, contains('settings'));
      await f.dispose(tester);
    },
  );

  testWidgets(
    'chapter, mode and viewport changes retain the lock; another comic resets it',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.lock(tester);
      final original = f.shell;
      f.chapter = 2;
      f.gallery = false;
      await f.mount(tester);
      await tester.pumpAndSettle();
      expect(f.shell, same(original));
      expect(f.shell.isMenuLocked, isTrue);
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(f.shell.isMenuLocked, isTrue);
      f.comicId = 'another book';
      await f.mount(tester);
      await tester.pumpAndSettle();
      expect(f.shell.isMenuLocked, isFalse);
      await f.lock(tester);
      f.sourceKey = 'another source';
      await f.mount(tester);
      await tester.pumpAndSettle();
      expect(f.shell.isMenuLocked, isFalse);
      await f.lock(tester);
      await tester.pumpWidget(const SizedBox());
      await f.mount(tester);
      expect(f.shell.isMenuLocked, isFalse);
      await f.dispose(tester);
    },
  );

  testWidgets(
    'TV confirmation unlocks without opening the menu; page and back keys remain available',
    (tester) async {
      final f = _Fixture()..tv = true;
      await f.mount(tester);
      await tester.pumpAndSettle();
      await f.lock(tester);
      f.calls.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(f.calls.any((call) => call.startsWith('remote ')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(f.shell.isMenuLocked, isFalse);
      expect(f.shell.isOpen, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(f.shell.isOpen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      f.shell.lockMenu();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(f.calls, contains('exit'));
      await f.dispose(tester);
    },
  );

  for (final scenario in [
    (size: const Size(375, 667), scale: 1.0, brightness: Brightness.light),
    (size: const Size(667, 375), scale: 3.2, brightness: Brightness.dark),
    (size: const Size(1024, 768), scale: 2.0, brightness: Brightness.light),
  ]) {
    testWidgets(
      'edge lock is visible, accessible and within safe insets at ${scenario.size}',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final f = _Fixture()
          ..scale = scenario.scale
          ..brightness = scenario.brightness;
        await f.mount(tester);
        f.shell.openOrClose();
        await tester.pumpAndSettle();
        await captureUiRegression(
          tester,
          f.repaint,
          'menu-lock-action-${scenario.size.width.toInt()}',
        );
        await tester.tap(find.byKey(const ValueKey('reader-menu-lock')));
        await tester.pumpAndSettle();
        final lock = find.byKey(const ValueKey('reader-menu-unlock'));
        final bounds = tester.getRect(lock);
        expect(bounds.right, scenario.size.width - f.padding.right);
        expect(bounds.top, greaterThanOrEqualTo(f.padding.top));
        expect(
          bounds.bottom,
          lessThanOrEqualTo(scenario.size.height - f.padding.bottom),
        );
        expect(bounds.size, const Size(48, 48));
        expect(find.bySemanticsLabel('Unlock reader menu'), findsOneWidget);
        expect(find.bySemanticsLabel('Lock reader menu'), findsNothing);
        expect(find.bySemanticsLabel('Settings'), findsNothing);
        await captureUiRegression(
          tester,
          f.repaint,
          'menu-locked-${scenario.size.width.toInt()}',
        );
        expect(tester.takeException(), isNull);
        await f.dispose(tester);
        semantics.dispose();
      },
    );
  }
}
