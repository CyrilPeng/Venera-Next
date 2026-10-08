import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/comments_controller.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_widgets/comic_list.dart';
import 'package:venera_next/features/comic_details/comments_page.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  for (final raw in [
    false,
    <Object?>[12, null, 'BLOCKED'],
  ]) {
    testWidgets('chapter comments use current typed keyword view: $raw', (
      tester,
    ) async {
      final work = ImageWork();
      final comments = [
        for (final text in ['12 null visible', 'blocked comment'])
          Comment.fromJson({'userName': 'Reader', 'content': text}),
      ];
      Widget page() => MaterialApp(
        home: ChapterCommentsPage(
          work: work,
          request: ReaderChapterCommentsRequest(
            identity: Object(),
            sourceKey: 'source',
            comicTitle: 'Book',
            chapterTitle: 'Chapter',
            isCurrent: () => true,
            load: (_, _) async => Res(comments, subData: 1),
          ),
        ),
      );
      appdata.settings['blockedCommentWords'] = raw;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('12 null visible'), findsOneWidget);
      expect(
        find.text('blocked comment'),
        raw is List ? findsNothing : findsOneWidget,
      );
      expect(appdata.settings['blockedCommentWords'], same(raw));
      appdata.settings['blockedCommentWords'] = [];
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('blocked comment'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await work.dispose();
    });
  }
  setUp(() {
    final comics = appdata.settings['blockedWords'];
    final comments = appdata.settings['blockedCommentWords'];
    addTearDown(() {
      appdata.settings['blockedWords'] = comics;
      appdata.settings['blockedCommentWords'] = comments;
    });
  });
  const comic = Comic(
    'ALPHA title',
    '',
    'id',
    'subtitle',
    ['group:tag:tail'],
    'description',
    'source',
    null,
    null,
  );
  final comment = Comment.fromJson({
    'userName': 'Reader',
    'content': 'ALPHA 12 null',
  });

  test('comic filtering tolerates malformed storage without rewriting it', () {
    for (final raw in [
      null,
      false,
      'ALPHA',
      <Object?>[12, null, 'ALPHA'],
    ]) {
      appdata.settings['blockedWords'] = raw;
      expect(isBlocked(comic), raw is List ? 'ALPHA' : null);
      expect(appdata.settings['blockedWords'], same(raw));
    }
  });
  test('comment filtering ignores invalid entries and keeps case folding', () {
    for (final raw in [
      null,
      false,
      'alpha',
      <Object?>[12, null],
      ['aLpHa'],
    ]) {
      appdata.settings['blockedCommentWords'] = raw;
      expect(shouldBlockComment(comment), raw is List<String>);
      expect(appdata.settings['blockedCommentWords'], same(raw));
    }
  });
  test('comic matching keeps stored order, case and exact namespaced tags', () {
    for (final (words, result) in <(List<String>, String?)>[
      (['tag', 'ALPHA'], 'tag'),
      (['alpha'], null),
      (['tail'], null),
      (['group:tag:tail'], 'group:tag:tail'),
      (['subtitle'], 'subtitle'),
      (['description'], 'description'),
      ([''], ''),
    ]) {
      appdata.settings['blockedWords'] = words;
      expect(isBlocked(comic), result);
    }
  });
}
