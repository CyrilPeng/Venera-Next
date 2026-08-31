import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  tearDown(() => configureReaderChapterCompletedHandler(null));

  test('notifier emits only once per completed chapter', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final notifier = ReaderChapterCompletionNotifier(events.add);
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );
    await notifier.notify(isAtEnd: false, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    expect(events, [event]);
  });

  test('different chapter keys emit independently', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final notifier = ReaderChapterCompletionNotifier(events.add);
    const first = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );
    const second = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'two',
      chapterTitle: '第 2 话',
    );

    await notifier.notify(isAtEnd: true, event: first);
    await notifier.notify(isAtEnd: true, event: second);

    expect(events, [first, second]);
  });

  test('configured handler is captured and awaited', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final completed = Completer<void>();
    configureReaderChapterCompletedHandler((event) async {
      await completed.future;
      events.add(event);
    });
    final notifier = ReaderChapterCompletionNotifier();
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );

    var returned = false;
    final notification = notifier
        .notify(isAtEnd: true, event: event)
        .then((_) => returned = true);
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    completed.complete();
    await notification;

    expect(events, [event]);
  });

  test('notifier without a handler ignores completion', () async {
    configureReaderChapterCompletedHandler(null);
    final notifier = ReaderChapterCompletionNotifier();
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );

    await notifier.notify(isAtEnd: true, event: event);
  });

  test('completion position requires content and a valid final page', () {
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: false,
        page: 1,
        lastImagePage: 0,
        totalPages: 0,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 1,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 3,
        lastImagePage: 2,
        totalPages: 2,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 2,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isTrue,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 3,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isTrue,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: false,
        hasImages: true,
        page: 2,
        lastImagePage: 2,
        totalPages: 2,
      ),
      isFalse,
    );
  });

  test(
    'background completion is deferred until active and emitted once',
    () async {
      final events = <ReaderChapterCompletedEvent>[];
      final notifier = ReaderChapterCompletionNotifier(events.add);
      const event = ReaderChapterCompletedEvent(
        sourceKey: 'source',
        comicId: 'comic',
        chapterKey: 'one',
        chapterTitle: '第 1 话',
      );

      Future<void> check(bool isActive) => notifier.notify(
        isAtEnd: isReaderChapterCompletionPosition(
          isActive: isActive,
          hasImages: true,
          page: 1,
          lastImagePage: 1,
          totalPages: 1,
        ),
        event: event,
      );

      await check(false);
      expect(events, isEmpty);
      await check(true);
      await check(true);
      expect(events, [event]);
    },
  );

  test('ordinary chapter change enters loading before resetting its page', () {
    final location = _ReaderLocationHarness();

    expect(location.toChapter(2), isTrue);

    expect(location.chapter, 2);
    expect(location.completionChecks, 0);
    expect(location.contentReady, isFalse);
  });
}

class _ReaderLocationHarness with ReaderLocation {
  bool contentReady = true;
  int completionChecks = 0;

  @override
  String get cid => 'comic';

  @override
  bool get isLoading => false;

  @override
  int get maxChapter => 2;

  @override
  int get maxPage => 1;

  @override
  int get totalPages => maxPage;

  @override
  ComicType get type => ComicType.local;

  @override
  void onPageChanged() {
    if (contentReady && page >= maxPage) {
      completionChecks++;
    }
  }

  @override
  void onReaderContentLoading() {
    contentReady = false;
  }

  @override
  void update() {}
}
