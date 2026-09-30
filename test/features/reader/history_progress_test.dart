import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/reader/history_progress.dart';
import 'package:venera_next/features/reader/page_layout.dart';

History history() => History.fromMap({
  'type': 0,
  'time': 1000,
  'title': 'Book',
  'subtitle': 'Author',
  'cover': 'cover',
  'id': 'comic',
  'ep': 1,
  'page': 3,
  'max_page': 20,
  'readEpisode': ['1'],
  'read_duration_ms': 9000,
});

void main() {
  test(
    'grouped chapter identity uses expanded position even with repeated source IDs',
    () {
      final item = history();
      const chapters = ComicChapters.grouped({
        'first': {'shared': 'First', 'other': 'Other'},
        'second': {'shared': 'Different chapter'},
      });
      final time = DateTime(2026, 10, 1);
      applyReaderHistoryProgress(
        history: item,
        page: 2,
        imageCount: 10,
        chapter: 3,
        chapters: chapters,
        layout: const ReaderPageLayout(
          imagesPerPage: 2,
          singleImageOnFirstPage: true,
        ),
        time: time,
      );
      expect(item.page, 2);
      expect(item.maxPage, 10);
      expect(item.ep, 1);
      expect(item.group, 2);
      expect(item.readEpisode, {'1', '2-1'});
      expect(item.time, time);
      expect(item.readDurationMs, 9000);
      expect(item.title, 'Book');
      expect(item.id, 'comic');
    },
  );

  test(
    'last display and comment pages store the last source image, without duplicate read keys',
    () {
      final item = history()..group = 4;
      const layout = ReaderPageLayout(
        imagesPerPage: 2,
        singleImageOnFirstPage: false,
      );
      for (final page in [5, 6]) {
        applyReaderHistoryProgress(
          history: item,
          page: page,
          imageCount: 9,
          chapter: 2,
          chapters: const ComicChapters({'a': 'A', 'b': 'B'}),
          layout: layout,
          time: DateTime(2026),
        );
        expect(item.page, 9);
        expect(item.ep, 2);
        expect(item.maxPage, 9);
        expect(item.readEpisode, {'1', '2'});
        // The original ungrouped update leaves an existing group untouched.
        expect(item.group, 4);
      }
    },
  );

  test(
    'chapterless and empty content retain the existing history coordinates',
    () {
      final item = history();
      applyReaderHistoryProgress(
        history: item,
        page: 1,
        imageCount: 0,
        chapter: 1,
        chapters: null,
        layout: const ReaderPageLayout(
          imagesPerPage: 1,
          singleImageOnFirstPage: false,
        ),
        time: DateTime(2026),
      );
      expect(item.page, 0);
      expect(item.maxPage, 0);
      expect(item.group, isNull);
      expect(item.readEpisode, {'1'});
    },
  );
}
