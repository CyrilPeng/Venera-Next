import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/rich_comment_content.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  setUp(() {
    final previous = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = previous);
  });
  testWidgets(
    'replacing rich text updates content without accumulating spans',
    (tester) async {
      Future<void> show(String text) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RichCommentContent(text: text)),
        ),
      );
      await show('<b>Old</b> http://example.test/old');
      await show('<i>New</i> http://example.test/new');
      final text = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText();
      expect(text, 'New http://example.test/new');
      await show('<i>New</i> http://example.test/new');
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText))
            .textSpan!
            .toPlainText(),
        text,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('handled app link removes only the originating overlay', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext owner;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          owner = context;
          return const Scaffold(body: Text('Comment overlay'));
        },
      ),
    );
    await tester.pumpAndSettle();
    final pending = Completer<bool>();
    final task = openCommentLink(
      owner,
      'https://example.test/book',
      openAppLink: (_, active) => pending.future,
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Linked book')),
      ),
    );
    await tester.pumpAndSettle();
    pending.complete(true);
    await task;
    await tester.pumpAndSettle();
    expect(find.text('Linked book'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Comment overlay'), findsNothing);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'disposed link owner suppresses external fallback; throws=$throws',
      (tester) async {
        late BuildContext owner;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                owner = context;
                return const Scaffold();
              },
            ),
          ),
        );
        final pending = Completer<bool>();
        var launches = 0;
        final task = openCommentLink(
          owner,
          'https://example.test',
          openAppLink: (_, active) => pending.future,
          openExternal: (_) async {
            launches++;
            return true;
          },
        );
        await tester.pumpWidget(const SizedBox());
        if (throws) {
          pending.completeError(StateError('late'));
        } else {
          pending.complete(false);
        }
        await task;
        expect(launches, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unhandled live link launches externally without closing its route',
    (tester) async {
      late BuildContext owner;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              owner = context;
              return const Scaffold(body: Text('Comment'));
            },
          ),
        ),
      );
      var launches = 0;
      await openCommentLink(
        owner,
        'https://example.test',
        openAppLink: (_, active) async => false,
        openExternal: (_) async {
          launches++;
          return true;
        },
      );
      await tester.pumpAndSettle();
      expect(launches, 1);
      expect(find.text('Comment'), findsOneWidget);
    },
  );
}
