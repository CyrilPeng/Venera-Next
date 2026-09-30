import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/local_comics/local_reading.dart';

void main() {
  test('downloaded IDs follow current chapter order, not download order', () {
    final start = resolveLocalReadingStart(
      chapters: const ComicChapters({'a': 'A', 'b': 'B', 'c': 'C'}),
      downloadedChapters: ['c', 'b'],
    );
    expect(start, (chapter: 2, page: null, group: null));
  });

  test('history takes precedence and preserves page and group', () {
    final start = resolveLocalReadingStart(
      chapters: const ComicChapters({'a': 'A', 'b': 'B'}),
      downloadedChapters: ['a'],
      historyChapter: 2,
      historyPage: 17,
      historyGroup: 3,
    );
    expect(start, (chapter: 2, page: 17, group: 3));
  });

  test('missing chapter metadata leaves reader defaults intact', () {
    expect(resolveLocalReadingStart(chapters: null, downloadedChapters: []), (
      chapter: null,
      page: null,
      group: null,
    ));
  });

  test('grouped downloads retain the existing last matching group rule', () {
    final start = resolveLocalReadingStart(
      chapters: const ComicChapters.grouped({
        'one': {'a': 'A'},
        'two': {'b': 'B', 'c': 'C'},
      }),
      downloadedChapters: ['a', 'c'],
    );
    expect(start, (chapter: 2, page: null, group: 2));
  });
}
