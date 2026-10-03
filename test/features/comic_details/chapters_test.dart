import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/chapters.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  for (final reverse in [false, true]) {
    testWidgets(
      'normal chapter read marks follow original indices; reverse=$reverse',
      (tester) async {
        final previous = appdata.settings['reverseChapterOrder'];
        appdata.settings['reverseChapterOrder'] = reverse;
        addTearDown(() => appdata.settings['reverseChapterOrder'] = previous);
        final history = History(
          type: const ComicType(17),
          time: DateTime(2026),
          title: 'Book',
          subtitle: '',
          cover: '',
          ep: 2,
          page: 1,
          id: 'book',
          readEpisode: {'2'},
          maxPage: null,
          readDurationMs: 0,
        );
        final selected = <int>[];
        final theme = ThemeData();
        Future<void> show(History? value) => tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ComicChaptersView(
                    chapters: const ComicChapters({
                      'first-id': 'First chapter',
                      'other-id': 'Second chapter',
                    }),
                    history: value,
                    readChapter: selected.add,
                  ),
                ],
              ),
            ),
          ),
        );
        Color? color(String label) =>
            tester.widget<Text>(find.text(label)).style?.color;
        await show(history);
        expect(color('First chapter'), isNull);
        expect(color('Second chapter'), theme.colorScheme.outline);
        await tester.tap(find.text('Second chapter'));
        expect(selected, [2]);
        await show(null);
        expect(color('Second chapter'), isNull);
        await show(history.copy()..readEpisode = {'1'});
        expect(color('First chapter'), theme.colorScheme.outline);
        expect(color('Second chapter'), isNull);
      },
    );
  }
}
