import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/actions.dart';
import 'package:venera_next/features/comic_details/rating_dialog.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/res.dart';

class _Source extends Fake implements ComicSource {
  @override
  Future<void> closeDataWrites() async {}

  late LikeOrUnlikeComicFunc like;
  @override
  LikeOrUnlikeComicFunc get likeOrUnlikeComic => like;
}

class _Actions with ComicPageActions {
  _Actions(this.context, this.comicSource);
  @override
  final BuildContext context;
  @override
  final ComicSource comicSource;
  @override
  ComicDetails comic = ComicDetails.fromJson({
    'title': 'One',
    'cover': '',
    'tags': {},
    'sourceKey': 'test',
    'comicId': 'one',
  });
  @override
  History? get history => null;
  @override
  bool isComicActive(ComicDetails value) =>
      context.mounted && identical(comic, value);
  @override
  void update() {}
  @override
  void onReadEnd() {}
}

void main() {
  testWidgets(
    'like failure retries, duplicate requests collapse and stale result cannot change new comic',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final source = _Source();
      final actions = _Actions(context, source);
      source.like = (_, liked) => throw StateError('offline');
      await actions.likeOrUnlike();
      expect(actions.isLiking, isFalse);
      final pending = Completer<Res<bool>>();
      var calls = 0;
      source.like = (_, liked) {
        calls++;
        return pending.future;
      };
      final task = actions.likeOrUnlike();
      await actions.likeOrUnlike();
      expect(calls, 1);
      actions.comic = ComicDetails.fromJson({
        'title': 'Two',
        'cover': '',
        'tags': {},
        'sourceKey': 'test',
        'comicId': 'two',
      });
      expect(actions.isLiking, isFalse);
      source.like = (_, liked) async => const Res(true);
      await actions.likeOrUnlike();
      expect(actions.isLiked, isTrue);
      pending.complete(const Res(true));
      await task;
      expect(actions.isLiked, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rating defaults to displayed star and retries a thrown submission',
    (tester) async {
      var calls = 0;
      final pending = Completer<Res<bool>>();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ComicRatingDialog(
            submit: (rating) {
              expect(rating, 1);
              if (++calls == 1) throw StateError('offline');
              return pending.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.tap(find.text('Submit'));
      expect(calls, 2);
      pending.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failed in [false, true]) {
    testWidgets(
      'late rating result after dismissal preserves replacement; failed=$failed',
      (tester) async {
        final pending = Completer<Res<bool>>();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => ComicRatingDialog(submit: (_) => pending.future),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit'));
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Replacement')),
          ),
        );
        await tester.pumpAndSettle();
        if (failed) {
          pending.completeError(StateError('late'));
        } else {
          pending.complete(const Res(true));
        }
        await tester.pumpAndSettle();
        expect(find.text('Replacement'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
