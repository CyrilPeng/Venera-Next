import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/page_layout.dart';

void main() {
  test(
    'display ranges partition chapter images without gaps or duplicates',
    () {
      for (var count = 1; count <= 37; count++) {
        for (var perPage = 1; perPage <= 5; perPage++) {
          for (final singleFirst in [false, true]) {
            final layout = ReaderPageLayout(
              imagesPerPage: perPage,
              singleImageOnFirstPage: singleFirst,
            );
            final visited = <int>[];
            for (var page = 1; page <= layout.pageCount(count); page++) {
              final (start, end) = layout.imageRange(page, count);
              expect(start, visited.length);
              expect(end, greaterThan(start));
              expect(end - start, lessThanOrEqualTo(perPage));
              for (var index = start; index < end; index++) {
                expect(layout.pageForImage(index + 1), page);
                visited.add(index);
              }
            }
            expect(visited, List.generate(count, (i) => i));
          }
        }
      }
    },
  );

  test('cover grouping and incomplete last pages use stable image anchors', () {
    const cover = ReaderPageLayout(
      imagesPerPage: 2,
      singleImageOnFirstPage: true,
    );
    const paired = ReaderPageLayout(
      imagesPerPage: 2,
      singleImageOnFirstPage: false,
    );
    expect(
      [for (var i = 1; i <= 6; i++) cover.pageForImage(i)],
      [1, 2, 2, 3, 3, 4],
    );
    expect(cover.imageRange(4, 6), (5, 6));
    expect(paired.imageRange(3, 5), (4, 5));
    expect(cover.historyImage(2, 6), 2);
    expect(paired.historyImage(2, 6), 3);
    expect(paired.historyImage(3, 6), 6);
    expect(paired.historyImage(4, 6), 6);
    expect(cover.historyImage(5, 6), 6);
  });

  test(
    'layout transitions keep the old first image on the destination page',
    () {
      for (var count = 1; count <= 25; count++) {
        for (var oldSize = 1; oldSize <= 3; oldSize++) {
          for (var newSize = 1; newSize <= 3; newSize++) {
            for (final singleFirst in [false, true]) {
              final old = ReaderPageLayout(
                imagesPerPage: oldSize,
                singleImageOnFirstPage: singleFirst,
              );
              final next = ReaderPageLayout(
                imagesPerPage: newSize,
                singleImageOnFirstPage: singleFirst,
              );
              for (var page = 1; page <= old.pageCount(count); page++) {
                final anchor = old.firstImageOnPage(page) - 1;
                final remapped = old.remapPage(page, next, imageCount: count);
                final (start, end) = next.imageRange(remapped, count);
                expect(anchor, inInclusiveRange(start, end - 1));
              }
              expect(
                old.remapPage(
                  old.pageCount(count) + 1,
                  next,
                  imageCount: count,
                ),
                next.pageCount(count) + 1,
              );
            }
          }
        }
      }
    },
  );

  test('loading and empty-chapter page counts preserve existing semantics', () {
    const single = ReaderPageLayout(
      imagesPerPage: 1,
      singleImageOnFirstPage: false,
    );
    const paired = ReaderPageLayout(
      imagesPerPage: 2,
      singleImageOnFirstPage: false,
    );
    const cover = ReaderPageLayout(
      imagesPerPage: 2,
      singleImageOnFirstPage: true,
    );
    expect(paired.pageCount(null), 1);
    expect(single.pageCount(0), 0);
    expect(paired.pageCount(0), 0);
    expect(cover.pageCount(0), 1);
    expect(cover.imageRange(1, 0), (0, 0));
    expect(paired.remapPage(0, single, imageCount: null), 1);
    expect(paired.remapPage(2, single, imageCount: null), 2);
    expect(paired.historyImage(1, 0), 0);
  });
}
