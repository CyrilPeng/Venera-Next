import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/navigation_bar.dart';
import 'package:venera_next/foundation/app_page_route.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/features/local_comics/local_comic_image.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

const _flightKey = ValueKey('cover-flight');

Widget _page(
  int page, {
  bool detail = false,
  bool failed = false,
  bool gesture = false,
  ImageProvider? cover,
}) => Material(
  key: ValueKey('page-$page-$detail'),
  child: Align(
    alignment: detail ? Alignment.topRight : Alignment.bottomLeft,
    child: Hero(
      tag: 'cover-$page',
      transitionOnUserGestures: gesture,
      flightShuttleBuilder: (_, _, _, _, _) =>
          const ColoredBox(key: _flightKey, color: Colors.orange),
      child: SizedBox(
        width: detail ? 144 : 80,
        height: detail ? 200 : 110,
        child: failed
            ? const Icon(Icons.error)
            : cover == null
            ? ColoredBox(color: detail ? Colors.green : Colors.blue)
            : AnimatedImage(image: cover, fit: BoxFit.cover),
      ),
    ),
  ),
);

class _Harness {
  _Harness({this.covers = const []});
  final List<ImageProvider> covers;
  final pane = GlobalKey<NaviPaneState>();
  final navigation = ValueNotifier(GlobalKey<NavigatorState>());
  final rebuild = ValueNotifier(0);
  final observer = NaviObserver();
  bool _gesture = false;

  NavigatorState get navigator => navigation.value.currentState!;
  HeroController get hero =>
      HeroControllerScope.of(navigation.value.currentContext!);

  Future<void> mount(
    WidgetTester tester, {
    bool failed = false,
    bool gesture = false,
  }) async {
    _gesture = gesture;
    addTearDown(navigation.dispose);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: Listenable.merge([navigation, rebuild]),
          builder: (_, _) => NaviPane(
            key: pane,
            paneItems: [
              PaneItemEntry(
                label: 'First',
                icon: Icons.home,
                activeIcon: Icons.home,
              ),
              PaneItemEntry(
                label: 'Second',
                icon: Icons.book,
                activeIcon: Icons.book,
              ),
            ],
            paneActions: const [],
            pageBuilder: (page) => _page(
              page,
              failed: failed,
              gesture: gesture,
              cover: covers.isEmpty ? null : covers[page],
            ),
            observer: observer,
            navigatorKey: navigation.value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void push(int page, {bool failed = false}) => navigator.push<void>(
    AppPageRoute<void>(
      builder: (_) => _page(
        page,
        detail: true,
        failed: failed,
        gesture: _gesture,
        cover: covers.isEmpty ? null : covers[page],
      ),
    ),
  );
}

class _LocalCover extends LocalComicImageProvider {
  _LocalCover(this.file, int index)
    : super(
        LocalComic(
          id: 'hero-local-$index',
          title: 'Local comic $index',
          subtitle: '',
          tags: const [],
          directory: '',
          chapters: null,
          cover: '',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime(2026),
        ),
      );
  final File file;
  @override
  File get coverFile => file;
}

void main() {
  testWidgets('local file covers release flights across rapid tab switches', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'local-cover-flight-',
    );
    final covers = <ImageProvider>[];
    for (var i = 0; i < 2; i++) {
      final page = img.Image(width: 100, height: 160)
        ..clear(img.ColorRgb8(50 + i * 100, 100, 180));
      final file = File('${directory.path}/$i.png')
        ..writeAsBytesSync(img.encodePng(page));
      covers.add(_LocalCover(file, i));
    }
    final harness = _Harness(covers: covers);
    try {
      await harness.mount(tester);
      for (
        var attempt = 0;
        attempt < 100 &&
            find
                .byWidgetPredicate(
                  (widget) => widget is RawImage && widget.image != null,
                )
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
      }
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
        findsWidgets,
      );
      for (var round = 0; round < 4; round++) {
        harness.push(harness.pane.currentState!.currentPage);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        harness.pane.currentState!.updatePage(
          1 - harness.pane.currentState!.currentPage,
        );
        await tester.pump();
        harness.push(harness.pane.currentState!.currentPage);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        harness.navigator.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
        expect(harness.observer.routes, hasLength(1));
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pump();
      expect(
        directory.resolveSymbolicLinksSync(),
        startsWith(
          '${Directory.systemTemp.resolveSymbolicLinksSync()}${Platform.pathSeparator}',
        ),
      );
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets('the nested navigator retains its hero controller on rebuild', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final original = harness.hero;
    for (var i = 0; i < 5; i++) {
      harness.rebuild.value++;
      await tester.pump();
      expect(harness.hero, same(original));
    }
    harness.push(0);
    await tester.pumpAndSettle();
    expect(harness.hero, same(original));
    harness.navigator.pop();
    await tester.pumpAndSettle();
    expect(harness.hero, same(original));
  });

  for (final failed in [false, true]) {
    testWidgets(
      'cancelled back gesture clears the cover after rebuild: $failed',
      (tester) async {
        final harness = _Harness();
        // Gesture opt-in isolates Flutter's no-progress cancellation cleanup.
        await harness.mount(tester, failed: failed, gesture: true);
        harness.push(0, failed: failed);
        await tester.pumpAndSettle();
        harness.navigator.didStartUserGesture();
        await tester.pump();
        await tester.pump();
        expect(find.byKey(_flightKey), findsOneWidget);
        harness.rebuild.value++;
        await tester.pump();
        harness.navigator.didStopUserGesture();
        await tester.pumpAndSettle();
        expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
        expect(harness.observer.routes, hasLength(2));
        harness.navigator.pop();
        await tester.pumpAndSettle();
        expect(harness.observer.routes, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('replacing a navigator also replaces its hero controller', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    harness.push(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final original = harness.hero;
    harness.navigation.value = GlobalKey<NavigatorState>();
    await tester.pumpAndSettle();
    expect(harness.hero, isNot(same(original)));
    expect(harness.hero.navigator, same(harness.navigator));
    expect(original.navigator, isNull);
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    harness.push(0);
    await tester.pumpAndSettle();
    harness.navigator.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final switchMs in [0, 30, 150, 290, 310]) {
    for (final repushMs in [0, 30, 170]) {
      testWidgets(
        'rapid tab switch clears cover flights: $switchMs/$repushMs',
        (tester) async {
          final harness = _Harness();
          await harness.mount(tester);
          for (var round = 0; round < 3; round++) {
            final current = harness.pane.currentState!.currentPage;
            harness.push(current);
            await tester.pump();
            await tester.pump(Duration(milliseconds: switchMs));
            harness.pane.currentState!.updatePage(1 - current);
            await tester.pump();
            await tester.pump(Duration(milliseconds: repushMs));
            harness.push(1 - current, failed: true);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));
            harness.navigator.pop();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
            expect(harness.observer.routes, hasLength(1));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
