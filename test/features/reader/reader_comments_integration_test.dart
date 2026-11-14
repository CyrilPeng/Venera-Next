import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicSourceManager;
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';

import 'support/reader_integration_fixture.dart';

void main() {
  setUpReaderIntegration();

  testWidgets(
    'embedded comments exit waits for reader save and retains failed route',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final source = ReaderFixtureCommentSource();
      final restore = readerFixtureCommentRegistry(() => source);
      final saving = Completer<void>();
      try {
        appdata.settings['showChapterComments'] = true;
        appdata.settings['showChapterCommentsAtEnd'] = true;
        await fixture.mount(tester, pushed: true);
        final reader = fixture.readerKey.currentState!;
        reader.toPage(reader.maxPage + 1, animated: false);
        await tester.pumpAndSettle();
        final exit = find.descendant(
          of: find.byType(EmbeddedChapterCommentsPage),
          matching: find.byTooltip('Exit'),
        );
        expect(exit, findsOneWidget);
        fixture.history.onProgress = (_) => saving.future;
        await tester.tap(exit);
        await tester.pump();
        expect(fixture.readerKey.currentState, same(reader));
        saving.completeError(StateError('Comments exit save failed'));
        // Recovery can restart native image work. Wait for the exit outcome
        // while allowing its real I/O and codec futures to complete.
        await pumpReaderUntil(
          tester,
          () => find
              .text('Unable to close. Please try again.')
              .evaluate()
              .isNotEmpty,
        );
        expect(fixture.readerKey.currentState, same(reader));
        expect(find.text('Unable to close. Please try again.'), findsOneWidget);
        fixture.history.onProgress = null;
        await tester.tap(exit);
        await pumpReaderUntil(
          tester,
          () => fixture.readerKey.currentState == null,
        );
        await tester.pumpAndSettle();
        expect(fixture.readerKey.currentState, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        if (!saving.isCompleted) saving.complete();
        await fixture.dispose(tester);
        restore();
      }
    },
  );

  for (final embedded in [false, true]) {
    for (final changeSource in [false, true]) {
      testWidgets(
        'reader retires replies on original target change; embedded=$embedded source=$changeSource',
        (tester) async {
          final fixture = await ReaderIntegrationFixture.create(tester);
          final titles = {'one': 'One'};
          var source = ReaderFixtureCommentSource()
            ..load = () async => Res([
              Comment.fromJson({
                'id': 'root',
                'userName': 'Reader',
                'content': 'Original comment',
                'replyCount': 1,
              }),
            ], subData: 1);
          final restore = readerFixtureCommentRegistry(() => source);
          try {
            appdata.settings['showChapterComments'] = true;
            appdata.settings['showChapterCommentsAtEnd'] = true;
            await fixture.mount(
              tester,
              pushed: false,
              chapters: ComicChapters(titles),
            );
            final reader = fixture.readerKey.currentState!;
            if (embedded) {
              reader.toPage(reader.maxPage + 1, animated: false);
            } else {
              tester
                  .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
                  .openChapterComments();
            }
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Replies').hitTestable().last);
            await tester.pumpAndSettle();
            expect(
              find.byType(ChapterCommentsPage),
              findsNWidgets(embedded ? 1 : 2),
            );
            if (changeSource) {
              source = ReaderFixtureCommentSource()
                ..load = () async => Res([
                  readerFixtureComment('Replacement source'),
                ], subData: 1);
              // Source publication must retire the original route without a
              // manual ReaderState.update or an unrelated widget rebuild.
              ComicSourceManager.current!.notifyStateChange();
            } else {
              titles['one'] = 'Renamed chapter';
              reader.update();
            }
            await tester.pumpAndSettle();
            expect(find.byType(ChapterCommentsPage), findsNothing);
            expect(
              appNavigation.rootNavigatorKey.currentState!.canPop(),
              false,
            );
            if (embedded && changeSource) {
              expect(find.text('Replacement source'), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
            restore();
          }
        },
      );
    }
  }

  testWidgets(
    'actual gallery replaces comment source while keeping its viewport',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final pending = Completer<Res<List<Comment>>>();
      var source = ReaderFixtureCommentSource()..load = () => pending.future;
      final restore = readerFixtureCommentRegistry(() => source);
      try {
        appdata.settings['showChapterComments'] = true;
        appdata.settings['showChapterCommentsAtEnd'] = true;
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        reader.toPage(reader.maxPage + 1, animated: false);
        await tester.pump();
        final gallery = tester.state<GalleryModeState>(
          find.byType(ReaderGalleryView),
        );
        final original = reader.createChapterCommentsRequest()!;
        source = ReaderFixtureCommentSource()
          ..load = () async =>
              Res([readerFixtureComment('New source comment')], subData: 1);
        reader.update();
        await tester.pumpAndSettle();
        expect(
          tester.state<GalleryModeState>(find.byType(ReaderGalleryView)),
          same(gallery),
        );
        expect(original.isCurrent(), isFalse);
        expect(find.text('New source comment'), findsOneWidget);
        pending.complete(
          Res([readerFixtureComment('Old source comment')], subData: 1),
        );
        await tester.pumpAndSettle();
        expect(find.text('Old source comment'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete(Res([], subData: 1));
        await fixture.dispose(tester);
        restore();
      }
    },
  );

  for (final detached in [false, true]) {
    testWidgets('comment send delays actual core close; detached=$detached', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final pending = Completer<Res<bool>>();
      var calls = 0, closes = 0;
      final source = ReaderFixtureCommentSource()
        ..send = () {
          calls++;
          return pending.future;
        };
      final restore = readerFixtureCommentRegistry(() => source);
      final host = await readerFixtureHost(() => closes++);
      try {
        appdata.settings['showChapterComments'] = true;
        appdata.settings['showChapterCommentsAtEnd'] = true;
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          registry: host.selections,
        );
        final reader = fixture.readerKey.currentState!;
        reader.toPage(reader.maxPage + 1, animated: false);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Pending chapter comment',
        );
        await tester.tap(find.byIcon(Icons.send));
        expect(calls, 1);
        if (detached) await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = host.close().then((_) => closed = true);
        await tester.pump();
        expect(closed, isFalse);
        expect(closes, 0);
        pending.complete(const Res(true));
        await pumpReaderUntil(tester, () => closed);
        await closing;
        expect(closes, 1);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete(const Res(true));
        await fixture.dispose(tester);
        restore();
        await host.close();
      }
    });
  }
}
