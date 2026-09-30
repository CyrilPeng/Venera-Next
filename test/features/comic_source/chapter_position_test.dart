import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';

void main() {
  test('ungrouped chapters retain IDs, flat numbering and history keys', () {
    const chapters = ComicChapters({
      'z': 'Last alphabetically',
      'a': 'First alphabetically',
    });
    final first = chapters.positionAt(1);
    final last = chapters.positionAt(2);
    expect(first.id, 'z');
    expect(first.index, 1);
    expect(first.chapter, 1);
    expect(first.group, isNull);
    expect(first.isFirstInGroup, true);
    expect(first.isLastInGroup, false);
    expect(last.id, 'a');
    expect(last.historyKey, '2');
    expect(last.isLastInGroup, true);
    expect(chapters.chapterIndex(last.chapter, group: last.group), last.index);
  });

  test(
    'group-relative history round trips across empty and repeated-ID groups',
    () {
      const chapters = ComicChapters.grouped({
        'empty': {},
        'volume 1': {'a': 'A', 'b': 'B'},
        'gap': {},
        'volume 2': {'a': 'Another A', 'c': 'C', 'd': 'D'},
      });
      final positions = [for (var i = 1; i <= 5; i++) chapters.positionAt(i)];
      expect(positions.map((p) => p.id), ['a', 'b', 'a', 'c', 'd']);
      expect(positions.map((p) => p.historyKey), [
        '2-1',
        '2-2',
        '4-1',
        '4-2',
        '4-3',
      ]);
      expect(positions.map((p) => p.isFirstInGroup), [
        true,
        false,
        true,
        false,
        false,
      ]);
      expect(positions.map((p) => p.isLastInGroup), [
        false,
        true,
        false,
        false,
        true,
      ]);
      for (final position in positions) {
        expect(
          chapters.chapterIndex(position.chapter, group: position.group),
          position.index,
        );
      }
      expect(chapters.chapterIndex(4), 4);
    },
  );

  test('every chapter has exactly one matching group position', () {
    for (var first = 0; first <= 6; first++) {
      for (var second = 0; second <= 6; second++) {
        final chapters = ComicChapters.grouped({
          'first': {for (var i = 0; i < first; i++) 'first-$i': '$i'},
          'second': {for (var i = 0; i < second; i++) 'second-$i': '$i'},
        });
        for (var index = 1; index <= first + second; index++) {
          final position = chapters.positionAt(index);
          expect(position.group, index <= first ? 1 : 2);
          expect(position.chapter, inInclusiveRange(1, position.groupLength));
          expect(
            chapters.chapterIndex(position.chapter, group: position.group),
            index,
          );
          expect(chapters.ids.elementAt(index - 1), position.id);
        }
      }
    }
  });

  test('invalid resolved indices fail without inventing a chapter', () {
    const flat = ComicChapters({'one': 'One'});
    const grouped = ComicChapters.grouped({
      'empty': {},
      'book': {'one': 'One'},
    });
    for (final chapters in [
      flat,
      grouped,
      const ComicChapters({}),
      const ComicChapters.grouped({}),
    ]) {
      expect(() => chapters.positionAt(0), throwsRangeError);
      expect(() => chapters.positionAt(-1), throwsRangeError);
      expect(() => chapters.positionAt(2), throwsRangeError);
    }
  });
}
