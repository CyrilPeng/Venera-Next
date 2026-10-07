import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/progress_navigation.dart';

void main() {
  for (final reversed in [false, true]) {
    test(
      'progress edges retain chapter and endpoint policy reversed=$reversed',
      () {
        final calls = <String>[];
        ReaderProgressRequest request(int chapter, {int maxChapter = 3}) =>
            ReaderProgressRequest(
              identity: Object(),
              page: 3,
              maxPage: 5,
              chapter: chapter,
              maxChapter: maxChapter,
              reversed: reversed,
              isCurrent: () => true,
              toPage: (page, {animated = true}) {
                calls.add('page $page $animated');
                return true;
              },
              toChapter: (chapter) {
                calls.add('chapter $chapter');
                return true;
              },
            );
        void earlier(ReaderProgressRequest r) =>
            reversed ? r.next() : r.previous();
        void later(ReaderProgressRequest r) =>
            reversed ? r.previous() : r.next();
        earlier(request(1));
        later(request(1));
        earlier(request(2));
        later(request(2));
        later(request(3));
        earlier(request(1, maxChapter: 1));
        later(request(1, maxChapter: 1));
        expect(calls, [
          'page 1 true',
          'chapter 2',
          'chapter 1',
          'chapter 3',
          'page 5 true',
          'page 1 true',
          'page 5 true',
        ]);
      },
    );
  }

  test(
    'slider rejects comments tail and invalid pages, and skips animation',
    () {
      final pages = <int>[];
      final request = ReaderProgressRequest(
        identity: Object(),
        page: 6,
        maxPage: 5,
        chapter: 1,
        maxChapter: 2,
        reversed: false,
        isCurrent: () => true,
        toPage: (page, {animated = true}) {
          expect(animated, isFalse);
          pages.add(page);
          return true;
        },
        toChapter: (_) => throw StateError('unexpected chapter'),
      );
      expect(request.selectPage(0), isFalse);
      expect(request.selectPage(6), isFalse);
      expect(request.selectPage(5), isTrue);
      expect(request.selectPage(1), isTrue);
      expect(pages, [5, 1]);
    },
  );

  test('retired progress never dispatches and temporary holds can recover', () {
    var current = true;
    final pages = <int>[];
    final request = ReaderProgressRequest(
      identity: Object(),
      page: 1,
      maxPage: 5,
      chapter: 1,
      maxChapter: 2,
      reversed: false,
      isCurrent: () => current,
      toPage: (page, {animated = true}) {
        pages.add(page);
        return true;
      },
      toChapter: (_) => throw StateError('unexpected chapter'),
    );
    current = false;
    expect(request.selectPage(3), isFalse);
    expect(request.previous(), isFalse);
    expect(request.next(), isFalse);
    expect(pages, isEmpty);
    current = true;
    expect(request.selectPage(3), isTrue);
    expect(pages, [3]);
  });

  test('progress preserves rejected navigation results', () {
    final request = ReaderProgressRequest(
      identity: Object(),
      page: 1,
      maxPage: 1,
      chapter: 1,
      maxChapter: 2,
      reversed: false,
      isCurrent: () => true,
      toPage: (_, {animated = true}) => false,
      toChapter: (_) => false,
    );
    expect(request.selectPage(1), isFalse);
    expect(request.previous(), isFalse);
    expect(request.next(), isFalse);
  });
}
