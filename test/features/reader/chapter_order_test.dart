import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test('keeps source indices while reversing within each group', () {
    const order = ChapterReadingOrder([3, 2], reversed: true);
    expect(order.chapters, [3, 2, 1, 5, 4]);
    expect(order.next(1), 5);
    expect(order.previous(5), 1);
    expect(order.next(1, acrossGroups: false), isNull);
    expect(order.previous(5, acrossGroups: false), isNull);
  });

  for (final lengths in <List<int>>[
    [],
    [0],
    [1],
    [3],
    [2, 3],
    [0, 2, 0, 3, 0],
  ]) {
    for (final reversed in [false, true]) {
      test('adjacent chapters match $lengths with reversed=$reversed', () {
        final order = ChapterReadingOrder(lengths, reversed: reversed);
        final chapters = order.chapters.toList();
        var offset = 0;
        final groups = <int, int>{};
        for (var g = 0; g < lengths.length; g++) {
          for (var i = 0; i < lengths[g]; i++) {
            groups[++offset] = g;
          }
        }
        for (var i = 0; i < chapters.length; i++) {
          final chapter = chapters[i];
          final next = i + 1 < chapters.length ? chapters[i + 1] : null;
          final previous = i > 0 ? chapters[i - 1] : null;
          expect(order.next(chapter), next);
          expect(order.previous(chapter), previous);
          expect(
            order.next(chapter, acrossGroups: false),
            groups[chapter] == groups[next] ? next : null,
          );
          expect(
            order.previous(chapter, acrossGroups: false),
            groups[chapter] == groups[previous] ? previous : null,
          );
        }
        expect(order.next(0), isNull);
        expect(order.previous(0), isNull);
        expect(order.next(offset + 1), isNull);
        expect(order.previous(offset + 1), isNull);
      });
    }
  }

  test('chapter direction is comic specific and independent of overrides', () {
    final settings = appdata.settings;
    final previous = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    addTearDown(() {
      (previous as Map<String, dynamic>).forEach(
        (key, value) => settings[key] = value,
      );
    });
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['reverseChapterOrder'] = true;
    expect(settings.reverseChapterReading('book', 'source'), isFalse);
    settings.setReverseChapterReading('book', 'source', true);
    expect(settings.reverseChapterReading('book', 'source'), isTrue);
    expect(settings.reverseChapterReading('other', 'source'), isFalse);
    expect(settings.reverseChapterReading('book', 'other'), isFalse);
    expect(settings.isComicSpecificSettingsEnabled('book', 'source'), isFalse);
    settings.setEnabledComicSpecificSettings('book', 'source', true);
    settings.setEnabledComicSpecificSettings('book', 'source', false);
    expect(settings.reverseChapterReading('book', 'source'), isTrue);
    final encoded = jsonEncode(appdata.toJson()['settings']);
    settings['comicSpecificSettings'] = jsonDecode(
      encoded,
    )['comicSpecificSettings'];
    expect(settings.reverseChapterReading('book', 'source'), isTrue);
    settings.resetComicReaderSettings('book@source');
    expect(settings.reverseChapterReading('book', 'source'), isFalse);
  });
}
