import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_data.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  final binding = _FrameGateBinding();

  testWidgets('owner replacement releases the old navigation frame hold', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await fixture.mount(tester);
      // Complete real navigation without running its next frame callback.
      await tester.runAsync(() async {
        expect(fixture.state.toChapter(2), isTrue);
        await pumpEventQueue();
      });
      expect(fixture.navigation.state.chapter, 2);
      final retained = fixture.state;
      fixture.replaceOwner();
      await tester.pumpWidget(fixture.build());
      await fixture.waitForImages(tester);
      expect(fixture.state, same(retained));
      expect(fixture.state.autoReadingReady, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('old prepend frame cannot move the replacement owner', (
    tester,
  ) async {
    final fixture = _Fixture(chapter: 2);
    final before = Completer<List<String>>();
    fixture.load = (chapter, scope) => before.future;
    try {
      await fixture.mount(tester);
      expect(fixture.loads, [1]);
      final oldFrames = await binding.capture(() async {
        before.complete(List.filled(5, fixture.imageKey));
        await tester.idle();
      });
      expect(oldFrames, isNotEmpty);
      fixture.replaceOwner();
      fixture.load = (_, _) async => [fixture.imageKey];
      // Keep new source work held so only the retired callback can move it.
      final release = fixture.imageWork.holdForExit();
      await tester.pumpWidget(fixture.build());
      final previousOffset = fixture.state.scrollController.offset;
      final previousPage = fixture.navigation.state.page;
      await binding.replay(tester, oldFrames);
      expect(fixture.state.scrollController.offset, previousOffset);
      expect(fixture.navigation.state.page, previousPage);
      expect(fixture.navigation.state.chapter, 2);
      release();
      expect(tester.takeException(), isNull);
    } finally {
      if (!before.isCompleted) before.complete([fixture.imageKey]);
      await fixture.dispose(tester);
    }
  });

  testWidgets('old prepend completion cannot release a new prepend hold', (
    tester,
  ) async {
    final fixture = _Fixture(chapter: 2);
    final oldBefore = Completer<List<String>>();
    final newBefore = Completer<List<String>>();
    fixture.load = (_, _) => oldBefore.future;
    try {
      await fixture.mount(tester);
      final oldFrames = await binding.capture(() async {
        oldBefore.complete([fixture.imageKey]);
        await tester.idle();
      });
      // The first callback restores the anchor; retain its completion callback
      // across the owner change, where both controllers have revision zero.
      final oldCompletions = await binding.capture(
        () => binding.replay(tester, oldFrames),
      );
      expect(oldCompletions, isNotEmpty);
      fixture.replaceOwner();
      fixture.load = (_, _) => newBefore.future;
      await tester.pumpWidget(fixture.build());
      await tester.idle();
      fixture.state.onPositionChanged();
      await tester.idle();
      expect(fixture.loads, [1, 1]);
      final newFrames = await binding.capture(() async {
        newBefore.complete([fixture.imageKey]);
        await tester.idle();
      });
      expect(newFrames, isNotEmpty);
      await fixture.waitForImages(tester, expectReady: false);
      expect(fixture.state.autoReadingReady, isFalse);
      await binding.replay(tester, oldCompletions);
      expect(fixture.state.autoReadingReady, isFalse);
      await binding.replay(tester, newFrames);
      await fixture.waitForImages(tester);
      expect(fixture.state.autoReadingReady, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      if (!oldBefore.isCompleted) oldBefore.complete([fixture.imageKey]);
      if (!newBefore.isCompleted) newBefore.complete([fixture.imageKey]);
      await fixture.dispose(tester);
    }
  });

  testWidgets('pending navigation releases only its original owner loading', (
    tester,
  ) async {
    final fixture = _Fixture();
    final oldLoad = Completer<List<String>>();
    final newLoad = Completer<List<String>>();
    try {
      await fixture.mount(tester);
      fixture.load = (_, _) => oldLoad.future;
      fixture.state.toChapter(2);
      await tester.idle();
      expect(fixture.loading[0], [true]);
      fixture.replaceOwner();
      fixture.load = (_, _) => newLoad.future;
      await tester.pumpWidget(fixture.build());
      expect(fixture.loading[0], [true, false]);
      expect(fixture.loading[1], isNull);
      fixture.state.toChapter(2);
      await tester.idle();
      expect(fixture.loading[1], [true]);

      oldLoad.complete([fixture.imageKey]);
      await tester.idle();
      expect(fixture.loading[0], [true, false]);
      expect(fixture.loading[1], [true]);
      expect(fixture.navigation.state.chapter, 1);
      newLoad.complete([fixture.imageKey]);
      await fixture.waitForImages(tester);
      expect(fixture.navigation.state.chapter, 2);
      expect(fixture.loading[1], [true, false]);
      expect(tester.takeException(), isNull);
    } finally {
      if (!oldLoad.isCompleted) oldLoad.complete([fixture.imageKey]);
      if (!newLoad.isCompleted) newLoad.complete([fixture.imageKey]);
      await fixture.dispose(tester);
    }
  });

  testWidgets('unmount does not publish readiness over replacement content', (
    tester,
  ) async {
    final fixture = _Fixture();
    final load = Completer<List<String>>();
    try {
      await fixture.mount(tester);
      fixture.load = (_, _) => load.future;
      fixture.state.toChapter(2);
      await tester.idle();
      expect(fixture.loading[0], [true]);
      // ReaderImages starts the main load before its build removes this view.
      // Disposal must retire the old signal without a false/ready notification.
      await tester.pumpWidget(const CircularProgressIndicator());
      load.complete([fixture.imageKey]);
      await tester.idle();
      expect(fixture.loading[0], [true]);
      expect(tester.takeException(), isNull);
    } finally {
      if (!load.isCompleted) load.complete([fixture.imageKey]);
      await fixture.dispose(tester);
    }
  });
}

/// Hold actual callbacks registered by the real scrolling widget. Capturing a
/// narrow completion window lets old and new controller callbacks interleave
/// without exposing private production state or replacing image work.
class _FrameGateBinding extends AutomatedTestWidgetsFlutterBinding {
  List<FrameCallback>? _captured;

  @override
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  }) {
    final captured = _captured;
    if (captured == null || debugLabel != 'callback') {
      super.addPostFrameCallback(callback, debugLabel: debugLabel);
    } else {
      captured.add(callback);
    }
  }

  Future<List<FrameCallback>> capture(Future<void> Function() action) async {
    assert(_captured == null);
    final callbacks = _captured = <FrameCallback>[];
    try {
      await action();
    } finally {
      _captured = null;
    }
    return callbacks;
  }

  Future<void> replay(
    WidgetTester tester,
    List<FrameCallback> callbacks,
  ) async {
    for (final callback in callbacks) {
      super.addPostFrameCallback(callback);
    }
    await tester.pump();
  }
}

class _Fixture {
  _Fixture({int chapter = 1}) {
    navigation =
        ReaderController(
            pageCount: () => 3,
            chapterCount: () => 2,
            animationEnabled: () => false,
            viewport: () => viewport.current,
            onChanged: () {},
            onPageChanged: () {},
            onError: (error, _) => fail('$error'),
          )
          ..restoreChapter(chapter)
          ..replaceChapterImages(List.filled(3, imageKey));
  }

  final directory = Directory.systemTemp.createTempSync('continuous-owner-');
  late final File file = File('${directory.path}/page.png')
    ..writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 80)));
  late final imageKey = 'file://${file.path}';
  final viewport = ReaderViewportBinding();
  final owners = [ImageWork()];
  ImageWork get imageWork => owners.last;
  late final ReaderController navigation;
  final loads = <int>[];
  final loading = <int, List<bool>>{};
  Future<List<String>> Function(int, RequestScope)? load;
  ContinuousModeState get state => viewport.current! as ContinuousModeState;

  void replaceOwner() => owners.add(ImageWork());

  void Function(bool) _loadingCallback() {
    final owner = owners.length - 1;
    return (value) => loading.putIfAbsent(owner, () => []).add(value);
  }

  Widget build() => MaterialApp(
    home: ReaderContinuousView(
      imageWork: imageWork,
      data: const ReaderContinuousData(
        vertical: true,
        reverse: false,
        crossChapter: true,
        firstChapter: true,
        lastChapter: false,
        maxChapter: 2,
        preloadCount: 0,
        splitWideImages: false,
        invertSplit: false,
        scrollSpeed: 1,
        limitImageWidth: false,
        sideMargin: 0,
        doubleTapCollect: false,
        centerLongPressZoom: true,
        sourceKey: null,
        comicId: 'book',
      ),
      navigation: navigation,
      loadChapter: (chapter, scope) {
        loads.add(chapter);
        return load?.call(chapter, scope) ?? Future.value([imageKey]);
      },
      chapterId: (chapter) => 'id-$chapter',
      chapterTitle: (chapter) => 'Title $chapter',
      onViewportChanged: viewport.update,
      onUpdate: () {},
      onFloatingButton: (_) {},
      onCollectImage: () {},
      onActiveChapterChanged: () {},
      onContentLoading: _loadingCallback(),
      onPreviousError: (error, _) => fail('$error'),
      onNavigationError: (_, error, _) => fail('$error'),
      readerSize: () => const Size(800, 600),
      readImage: (_) => file.readAsBytes(),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(build());
    await waitForImages(tester);
  }

  Future<void> waitForImages(
    WidgetTester tester, {
    bool expectReady = true,
  }) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => pumpEventQueue());
      final images = state.imageStates.whereType<ComicImageState>().where(
        (image) => image.visibleInReader,
      );
      if (images.isNotEmpty &&
          images.every((image) => image.readyForAutoReading) &&
          (!expectReady || state.autoReadingReady)) {
        await tester.pump();
        return;
      }
    }
    fail('Visible native images did not become ready');
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final closing = Future.wait(owners.map((owner) => owner.dispose()));
    unawaited(closing.then((_) => closed = true));
    while (!closed) {
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }
    await closing;
    navigation.dispose();
    directory.deleteSync(recursive: true);
  }
}
