import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/comments_controller.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/res.dart';

class _Fixture {
  final work = ImageWork();
  final navigator = GlobalKey<NavigatorState>();
  final changed = ValueNotifier(0);
  final visible = ValueNotifier(true);
  final loads = <String?>[];
  final listeners = <VoidCallback>{};
  bool current = true;
  int revision = 0;
  Completer<Res<bool>>? sending;
  int sends = 0;

  late ReaderChapterCommentsRequest request = makeRequest();

  ReaderChapterCommentsRequest makeRequest() {
    final original = revision;
    return ReaderChapterCommentsRequest(
      identity: (this, original),
      sourceKey: 'fixture',
      comicTitle: 'Book',
      chapterTitle: 'Chapter $original',
      isCurrent: () => current && revision == original,
      observeValidity: (listener) {
        listeners.add(listener);
        changed.addListener(listener);
        return () {
          listeners.remove(listener);
          changed.removeListener(listener);
        };
      },
      load: (page, reply) async {
        loads.add(reply);
        return Res([
          Comment.fromJson({
            'id': reply == null ? 'root' : '$reply-child',
            'userName': 'Reader',
            'content': 'Body ${reply ?? 'root'}',
            'replyCount': 1,
          }),
        ], subData: 1);
      },
      send: (text, reply) {
        sends++;
        return sending?.future ?? Future.value(const Res(true));
      },
    );
  }

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, _) => show
            ? EmbeddedChapterCommentsPage(
                request: request,
                work: work,
                onExit: () async {},
              )
            : const Text('Library'),
      ),
    ),
  );

  Future<void> openReply(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Replies').hitTestable().last);
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    if (sending?.isCompleted == false) sending!.complete(const Res(true));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await work.dispose();
    expect(listeners, isEmpty);
    changed.dispose();
    visible.dispose();
  }
}

void main() {
  late Object? previousLanguage, previousBlocked;
  setUp(() {
    previousLanguage = appdata.settings['language'];
    previousBlocked = appdata.settings['blockedCommentWords'];
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedCommentWords'] = <String>[];
  });
  tearDown(() {
    appdata.settings['language'] = previousLanguage;
    appdata.settings['blockedCommentWords'] = previousBlocked;
  });

  testWidgets(
    'duplicate reply callbacks open one route with existing options',
    (tester) async {
      final fixture = _Fixture();
      try {
        await tester.pumpWidget(fixture.app());
        await tester.pumpAndSettle();
        final open = tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.insert_comment_outlined),
            )
            .onPressed!;
        open();
        open();
        await tester.pumpAndSettle();
        expect(fixture.loads, [null, 'root']);
        final route = ModalRoute.of(tester.element(find.byTooltip('Back')))!;
        expect(route, isA<SideBarRoute<void>>());
        final sidebar = route as SideBarRoute<void>;
        expect(sidebar.width, 500);
        expect(sidebar.showBarrier, false);
        expect(sidebar.addTopPadding, false);
        expect(sidebar.addBottomPadding, true);
        expect(sidebar.transitionDuration, Duration.zero);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(fixture.listeners, hasLength(1));
        await fixture.openReply(tester);
        expect(fixture.loads, [null, 'root', 'root']);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final invalidate in [false, true]) {
    testWidgets('nested replies retire with their owner; signal=$invalidate', (
      tester,
    ) async {
      final fixture = _Fixture();
      try {
        await tester.pumpWidget(fixture.app());
        await tester.pumpAndSettle();
        await fixture.openReply(tester);
        await fixture.openReply(tester);
        expect(fixture.listeners, hasLength(3));
        if (invalidate) {
          fixture.current = false;
          fixture.changed.value++;
        } else {
          fixture.visible.value = false;
        }
        await tester.pumpAndSettle();
        expect(find.byType(ChapterCommentsPage), findsNothing);
        expect(fixture.navigator.currentState!.canPop(), false);
        expect(fixture.listeners, hasLength(invalidate ? 1 : 0));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('removing a covered reply preserves the unrelated top route', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      await fixture.openReply(tester);
      final other = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      );
      unawaited(fixture.navigator.currentState!.push(other));
      await tester.pumpAndSettle();
      fixture.visible.value = false;
      await tester.pumpAndSettle();
      expect(other.isActive, true);
      expect(find.text('Other page'), findsOneWidget);
      fixture.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);
      expect(fixture.navigator.currentState!.canPop(), false);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('replacement rejects a saved old reply action', (tester) async {
    final fixture = _Fixture();
    try {
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      final old = tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.insert_comment_outlined),
          )
          .onPressed!;
      await fixture.openReply(tester);
      fixture.revision++;
      fixture.request = fixture.makeRequest();
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      expect(find.byType(ChapterCommentsPage), findsNothing);
      old();
      await tester.pumpAndSettle();
      expect(fixture.navigator.currentState!.canPop(), false);
      await fixture.openReply(tester);
      expect(
        find.descendant(
          of: find.byType(ChapterCommentsPage),
          matching: find.text('Chapter 1'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'retiring a reply retains its accepted send in the original work',
    (tester) async {
      final fixture = _Fixture()..sending = Completer<Res<bool>>();
      try {
        await tester.pumpWidget(fixture.app());
        await tester.pumpAndSettle();
        await fixture.openReply(tester);
        await tester.enterText(find.byType(TextField).hitTestable(), 'Reply');
        await tester.tap(find.byTooltip('Send').hitTestable());
        await tester.pump();
        fixture.current = false;
        fixture.changed.value++;
        await tester.pumpAndSettle();
        var closed = false;
        final closing = fixture.work.dispose().then((_) => closed = true);
        await tester.pump();
        expect(closed, false);
        expect(fixture.sends, 1);
        fixture.sending!.complete(const Res(true));
        fixture.sending = null;
        await tester.pump();
        await closing;
        expect(closed, true);
        expect(fixture.navigator.currentState!.canPop(), false);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}
