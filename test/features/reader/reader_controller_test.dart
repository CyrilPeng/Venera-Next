import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/network/request_scope.dart';

class _Viewport implements ReaderNavigationViewport {
  final animations = <Completer<void>>[];
  int? page;
  int? chapter;
  bool handlesChapter = false;
  @override
  Future<void> animateToPage(int page) {
    final future = Completer<void>();
    animations.add(future);
    return future.future;
  }

  @override
  void toPage(int page) => this.page = page;
  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    this.chapter = chapter;
    return handlesChapter;
  }
}

void main() {
  late ReaderController controller;
  late _Viewport view;
  var updates = 0;
  var pageChanges = 0;
  var errors = 0;
  var attached = true;
  setUp(() {
    updates = pageChanges = errors = 0;
    attached = true;
    view = _Viewport();
    controller = ReaderController(
      pageCount: () => 300,
      chapterCount: () => 3,
      animationEnabled: () => true,
      viewport: () => attached ? view : null,
      onChanged: () => updates++,
      onPageChanged: () => pageChanges++,
      onError: (error, stack) => errors++,
    );
  });
  tearDown(() => controller.dispose());

  for (final phase in ['before', 'images', 'mode']) {
    test(
      'current $phase error stays in the UI without poisoning image work',
      () async {
        final work = ImageWork();
        final failure = StateError('current $phase failure');
        final result = await controller.loadContent(
          controller.beginContentLoad(),
          imageWork: work,
          beforeLoad: () async {
            if (phase == 'before') throw failure;
          },
          loadImages: (_) async {
            if (phase == 'images') throw failure;
            return ['current'];
          },
          prepareMode: () async {
            if (phase == 'mode') throw failure;
          },
        );
        expect(result, ReaderContentLoadResult.failed);
        expect(controller.content.error, failure.toString());
        (await work.prepareForExit())();
        await work.dispose();
      },
    );
  }

  test(
    'owned content suppresses cancellation sentinels after the original phase ends',
    () async {
      final work = ImageWork();
      final source = Completer<List<String>>();
      final attempt = controller.beginContentLoad();
      final loading = controller.loadContent(
        attempt,
        imageWork: work,
        beforeLoad: () async {},
        loadImages: (_) => source.future,
        prepareMode: () async => fail('cancelled content must not prepare'),
      );
      await pumpEventQueue();
      final preparing = work.prepareForExit();
      expect(attempt.scope.isCancelled, isTrue);
      source.completeError(const RequestCancelled());
      expect(await loading, ReaderContentLoadResult.ignored);
      (await preparing)();
      await work.dispose();
    },
  );

  test(
    'owned load deduplicates and completes only after mode preparation',
    () async {
      final attempt = controller.beginContentLoad();
      final preparing = Completer<void>();
      final readyToPrepare = Completer<void>();
      final pending = controller.loadContent(
        attempt,
        beforeLoad: () async {},
        loadImages: (_) async => ['one'],
        prepareMode: () {
          readyToPrepare.complete();
          return preparing.future;
        },
      );
      await readyToPrepare.future;
      expect(controller.content.images, ['one']);
      expect(controller.content.isLoading, isTrue);
      expect(
        await controller.loadContent(
          attempt,
          beforeLoad: () async => fail('duplicate preparation'),
          loadImages: (_) async => throw StateError('duplicate request'),
          prepareMode: () async => fail('duplicate mode'),
        ),
        ReaderContentLoadResult.ignored,
      );
      preparing.complete();
      expect(await pending, ReaderContentLoadResult.ready);
      expect(controller.content.isLoading, isFalse);
    },
  );

  for (final phase in ['before', 'images', 'mode']) {
    test('owned load reports $phase failure and can retry', () async {
      final result = await controller.loadContent(
        controller.beginContentLoad(),
        beforeLoad: () async {
          if (phase == 'before') throw StateError(phase);
        },
        loadImages: (_) async {
          if (phase == 'images') throw StateError(phase);
          return ['one'];
        },
        prepareMode: () async {
          if (phase == 'mode') throw StateError(phase);
        },
      );
      expect(result, ReaderContentLoadResult.failed);
      expect(controller.content.error, contains(phase));
      expect(controller.content.isLoading, isFalse);
      expect(
        await controller.loadContent(
          controller.beginContentLoad(),
          beforeLoad: () async {},
          loadImages: (_) async => ['retry'],
          prepareMode: () async {},
        ),
        ReaderContentLoadResult.ready,
      );
      expect(controller.content.images, ['retry']);
      expect(controller.content.error, isNull);
    });

    for (final dispose in [false, true]) {
      test(
        'interrupting $phase prevents later phases; dispose=$dispose',
        () async {
          final reached = Completer<void>();
          final release = Completer<void>();
          final phases = <String>[];
          Future<void> enter(String current) async {
            phases.add(current);
            if (current == phase) {
              reached.complete();
              await release.future;
            }
          }

          final attempt = controller.beginContentLoad();
          final pending = controller.loadContent(
            attempt,
            beforeLoad: () => enter('before'),
            loadImages: (_) async {
              await enter('images');
              return ['stale'];
            },
            prepareMode: () => enter('mode'),
          );
          await reached.future;
          if (dispose) {
            controller.dispose();
          } else {
            await controller.loadContent(
              controller.beginContentLoad(),
              beforeLoad: () async {},
              loadImages: (_) async => ['current'],
              prepareMode: () async {},
            );
          }
          final snapshot = controller.content;
          release.complete();
          expect(await pending, ReaderContentLoadResult.ignored);
          expect(controller.content, same(snapshot));
          expect(attempt.scope.isCancelled, isTrue);
          expect(
            phases,
            [
              'before',
              'images',
              'mode',
            ].take(['before', 'images', 'mode'].indexOf(phase) + 1).toList(),
          );
        },
      );
    }
  }

  test('content attempts cancel predecessors and reject stale results', () {
    final old = controller.beginContentLoad();
    expect(controller.startContentLoad(old), true);
    expect(controller.startContentLoad(old), false);
    final current = controller.beginContentLoad();
    expect(old.scope.isCancelled, true);
    expect(controller.setContentImages(old, ['old']), false);
    expect(controller.failContentLoad(old, 'late error'), false);
    controller.cancelContentLoad(old);
    expect(current.scope.isCancelled, false);
    expect(controller.startContentLoad(current), true);
    expect(controller.setContentImages(current, ['new']), true);
    expect(controller.completeContentLoad(current), true);
    expect(controller.content.images, ['new']);
    expect(controller.content.isLoading, false);
    expect(controller.failContentLoad(current, 'after completion'), false);
  });

  test(
    'content snapshots copy image lists and retain loading during preparation',
    () {
      final attempt = controller.beginContentLoad();
      controller.startContentLoad(attempt);
      final images = ['one', 'two'];
      controller.setContentImages(attempt, images);
      final preparing = controller.content;
      images.clear();
      expect(preparing.images, ['one', 'two']);
      expect(() => preparing.images!.clear(), throwsUnsupportedError);
      expect(preparing.isLoading, true);
      expect(controller.toPage(2), false);
      controller.completeContentLoad(attempt);
      expect(preparing.isLoading, true);
      expect(controller.content.isLoading, false);
    },
  );

  test(
    'retry clears content errors and waterfall activation cancels pending load',
    () {
      final failed = controller.beginContentLoad();
      controller.failContentLoad(failed, StateError('offline'));
      expect(controller.content.error, contains('offline'));
      final retry = controller.beginContentLoad();
      expect(controller.content.error, isNull);
      final segment = ['chapter-image'];
      controller.replaceChapterImages(segment);
      segment.clear();
      expect(retry.scope.isCancelled, true);
      expect(controller.content.images, ['chapter-image']);
      expect(controller.content.isLoading, false);
      expect(controller.completeContentLoad(retry), false);
    },
  );

  test('content disposal cancels owned scope and forbids future writes', () {
    final attempt = controller.beginContentLoad();
    controller.dispose();
    expect(attempt.scope.isCancelled, true);
    expect(controller.setContentImages(attempt, ['late']), false);
    expect(controller.completeContentLoad(attempt), false);
    expect(controller.failContentLoad(attempt, 'late'), false);
    expect(controller.beginContentLoad, throwsStateError);
    controller.replaceChapterImages(['late']);
    expect(controller.content.images, isNull);
  });

  test('immutable snapshots are cached until a state change', () {
    final before = controller.state;
    expect(controller.state, same(before));
    controller.restorePage(8);
    controller.restoreChapter(2);
    final after = controller.state;
    expect(before.page, 1);
    expect(before.chapter, 1);
    expect(after.page, 8);
    expect(after.chapter, 2);
    expect(pageChanges, 0);
    controller.setPage(9);
    expect(after.page, 8);
    expect(controller.state.page, 9);
    expect(pageChanges, 1);
  });

  test('invalid, loading and detached page commands do not reach viewport', () {
    expect(controller.toPage(0), false);
    expect(controller.toPage(301), false);
    final attempt = controller.beginContentLoad();
    expect(controller.toPage(2), false);
    controller.completeContentLoad(attempt);
    attached = false;
    expect(controller.toPage(2), false);
    expect(view.animations, isEmpty);
    expect(updates, 0);
    expect(controller.toChapter(4), false);
  });

  test(
    'replacement animation filters old viewport positions and completion',
    () async {
      controller.toPage(150);
      controller.toPage(200);
      controller.reportPage(150);
      expect(controller.state.page, 1);
      controller.reportPage(200);
      expect(controller.state.page, 200);
      view.animations.first.complete();
      await pumpEventQueue();
      expect(controller.state.pendingPage, 200);
      view.animations.last.complete();
      await pumpEventQueue();
      expect(controller.state.isAnimating, false);
    },
  );

  test(
    'chapter adapter handles loaded segments or falls back to chapter load',
    () {
      controller.restorePage(20);
      view.handlesChapter = true;
      expect(controller.toChapter(2), true);
      expect(controller.state.chapter, 1);
      expect(controller.state.page, 20);
      view.handlesChapter = false;
      expect(controller.toChapter(3, toLastPage: true), true);
      expect(controller.state.chapter, 3);
      expect(controller.state.page, 1);
      expect(controller.state.jumpToLastPageOnLoad, true);
      expect(pageChanges, 1);
      expect(updates, 1);
    },
  );

  test(
    'disposing ignores late animation failures and rejects commands',
    () async {
      controller.toPage(20);
      final previousUpdates = updates;
      controller.dispose();
      controller.dispose();
      view.animations.single.completeError(StateError('late failure'));
      await pumpEventQueue();
      controller.reportPage(20);
      controller.restorePage(30);
      controller.restoreChapter(2);
      controller.setJumpToLastPage(true);
      expect(controller.toPage(40), false);
      expect(controller.toChapter(2), false);
      expect(controller.state.page, 1);
      expect(controller.state.chapter, 1);
      expect(controller.state.jumpToLastPageOnLoad, false);
      expect(updates, previousUpdates);
      expect(errors, 0);
      expect(pageChanges, 0);
    },
  );
}
