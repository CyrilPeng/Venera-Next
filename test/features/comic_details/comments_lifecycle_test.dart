import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_details/comments_page.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

class _Source extends Fake implements ComicSource {
  @override
  Future<void> closeDataWrites() async {}

  Future<Res<List<Comment>>> Function(int) load = (_) async =>
      Res([], subData: 1);
  Future<Res<bool>> Function() send = () async => const Res(true);
  Future<Res<int?>> Function() react = () async => const Res(2);
  @override
  String get key => 'test';
  @override
  CommentsLoader get commentsLoader =>
      (_, sub, page, reply) => load(page);
  @override
  ChapterCommentsLoader get chapterCommentsLoader =>
      (_, ep, page, reply) => load(page);
  @override
  SendCommentFunc get sendCommentFunc =>
      (_, sub, text, reply) => send();
  @override
  SendChapterCommentFunc get sendChapterCommentFunc =>
      (_, ep, text, reply) => send();
  @override
  LikeCommentFunc get likeCommentFunc =>
      (_, sub, id, like) => react();
  @override
  VoteCommentFunc get voteCommentFunc =>
      (_, sub, id, up, cancel) => react();
}

Comment comment(String content) => Comment.fromJson({
  'userName': 'Reader',
  'content': content,
  'id': content,
  'score': 1,
});

void main() {
  setUp(() {
    final muted = Log.isMuted;
    final words = appdata.settings['blockedCommentWords'];
    Log.isMuted = true;
    appdata.settings['blockedCommentWords'] = [];
    addTearDown(() {
      Log.isMuted = muted;
      appdata.settings['blockedCommentWords'] = words;
    });
  });
  for (final kind in ['comic', 'chapter', 'embedded']) {
    Widget page(_Source source) => switch (kind) {
      'comic' => CommentsPage(
        source: source,
        data: ComicDetails.fromJson({
          'title': 'Book',
          'cover': '',
          'tags': {},
          'sourceKey': 'test',
          'comicId': 'book',
        }),
      ),
      'chapter' => ChapterCommentsPage(
        comicId: 'book',
        epId: 'ep',
        source: source,
        comicTitle: 'Book',
        chapterTitle: 'Chapter',
      ),
      _ => EmbeddedChapterCommentsPage(
        comicId: 'book',
        epId: 'ep',
        source: source,
        comicTitle: 'Book',
        chapterTitle: 'Chapter',
      ),
    };
    Future<void> show(WidgetTester tester, _Source source) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: page(source))));

    testWidgets(
      '$kind first-load deduplication and late failure after unmount',
      (tester) async {
        final source = _Source();
        final pending = Completer<Res<List<Comment>>>();
        var calls = 0;
        source.load = (_) {
          calls++;
          return pending.future;
        };
        await show(tester, source);
        await show(tester, source);
        expect(calls, 1);
        await tester.pumpWidget(const SizedBox());
        pending.completeError(StateError('late'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$kind synchronous first-load error can retry successfully', (
      tester,
    ) async {
      final source = _Source()..load = (_) => throw StateError('initial');
      await show(tester, source);
      await tester.pump();
      expect(find.byType(NetworkError), findsOneWidget);
      source.load = (_) async => Res([comment('Recovered')], subData: 1);
      tester.widget<NetworkError>(find.byType(NetworkError)).retry!();
      await tester.pumpAndSettle();
      expect(find.text('Recovered'), findsOneWidget);
      expect(find.byType(NetworkError), findsNothing);
    });

    testWidgets(
      '$kind send failure resets busy and duplicate taps submit once',
      (tester) async {
        final source = _Source();
        final pending = Completer<Res<bool>>();
        var calls = 0;
        source.send = () {
          calls++;
          return pending.future;
        };
        await show(tester, source);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Draft');
        await tester.tap(find.byIcon(Icons.send));
        await tester.tap(find.byIcon(Icons.send));
        expect(calls, 1);
        pending.completeError(StateError('send'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.send), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Draft',
        );
        source.send = () async {
          calls++;
          return const Res(true);
        };
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '',
        );
      },
    );

    for (final failed in [false, true]) {
      testWidgets('$kind send completion after unmount; failed=$failed', (
        tester,
      ) async {
        final source = _Source();
        final pending = Completer<Res<bool>>();
        source.send = () => pending.future;
        await show(tester, source);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Draft');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpWidget(const SizedBox());
        if (failed) {
          pending.completeError(StateError('late'));
        } else {
          pending.complete(const Res(true));
        }
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      '$kind pagination deduplicates, retries and ignores results before refresh',
      (tester) async {
        final source = _Source();
        var pageTwoCalls = 0;
        var pending = Completer<Res<List<Comment>>>();
        source.load = (page) {
          if (page == 1) {
            return Future.value(Res([comment('Initial')], subData: 2));
          }
          pageTwoCalls++;
          return pending.future;
        };
        await show(tester, source);
        await tester.pump();
        await tester.pump();
        await show(tester, source);
        expect(pageTwoCalls, 1);
        pending.completeError(StateError('more'));
        await tester.pumpAndSettle();
        expect(find.text('Bad state: more'), findsOneWidget);
        pending = Completer<Res<List<Comment>>>();
        await tester.tap(find.text('Bad state: more'));
        await tester.pump();
        expect(pageTwoCalls, 2);
        source.load = (_) async => Res([comment('Refreshed')], subData: 1);
        await tester.enterText(find.byType(TextField), 'Send');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        pending.complete(Res([comment('Stale')], subData: 2));
        await tester.pumpAndSettle();
        expect(find.text('Refreshed'), findsOneWidget);
        expect(find.text('Stale'), findsNothing);
      },
    );

    for (final icon in [Icons.favorite_border, Icons.arrow_upward]) {
      testWidgets(
        '$kind reaction error retries and late success is safe: $icon',
        (tester) async {
          final source = _Source()
            ..load = (_) async => Res([comment('React')], subData: 1);
          var pending = Completer<Res<int?>>();
          var calls = 0;
          source.react = () {
            calls++;
            return pending.future;
          };
          await show(tester, source);
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(icon));
          await tester.tap(find.byIcon(icon));
          expect(calls, 1);
          pending.completeError(StateError('reaction'));
          await tester.pumpAndSettle();
          pending = Completer<Res<int?>>();
          await tester.tap(find.byIcon(icon));
          expect(calls, 2);
          await tester.pumpWidget(const SizedBox());
          pending.complete(const Res(2));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
