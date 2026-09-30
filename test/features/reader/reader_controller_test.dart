import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader_controller.dart';

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
  var loading = false;
  var attached = true;
  setUp(() {
    updates = pageChanges = errors = 0;
    loading = false;
    attached = true;
    view = _Viewport();
    controller = ReaderController(
      pageCount: () => 300,
      chapterCount: () => 3,
      isLoading: () => loading,
      animationEnabled: () => true,
      viewport: () => attached ? view : null,
      onChanged: () => updates++,
      onPageChanged: () => pageChanges++,
      onError: (error, stack) => errors++,
    );
  });
  tearDown(() => controller.dispose());

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
    loading = true;
    expect(controller.toPage(2), false);
    loading = false;
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
