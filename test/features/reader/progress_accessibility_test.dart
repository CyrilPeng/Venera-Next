import 'dart:ui' show SemanticsAction, SemanticsActionEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/foundation/appdata.dart';

class _Fixture {
  _Fixture({this.reversed = false, this.textDirection = TextDirection.ltr});
  final bool reversed;
  final TextDirection textDirection;
  final before = FocusNode(), after = FocusNode();
  final calls = <int>[];
  var page = 3, count = 10;
  late StateSetter rebuild;
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: textDirection,
        child: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  TextButton(
                    focusNode: before,
                    onPressed: () {},
                    child: const Text('Before'),
                  ),
                  SizedBox(
                    width: 400,
                    child: ReaderProgressSlider(
                      page: page,
                      maxPage: count,
                      reversed: reversed,
                      onChanged: (value) => setState(() {
                        calls.add(value);
                        page = value;
                      }),
                    ),
                  ),
                  TextButton(
                    focusNode: after,
                    onPressed: () {},
                    child: const Text('After'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  Future<void> focusSlider(WidgetTester tester) async {
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      after.hasFocus,
      isFalse,
      reason: 'The slider participates in traversal.',
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    before.dispose();
    after.dispose();
  }
}

void main() {
  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });
  for (final reversed in [false, true]) {
    for (final direction in TextDirection.values) {
      testWidgets(
        'page keys follow reading direction, reversed=$reversed text=$direction',
        (tester) async {
          final f = _Fixture(reversed: reversed, textDirection: direction);
          await f.mount(tester);
          await f.focusSlider(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(f.page, reversed ? 2 : 4);
          await tester.sendKeyEvent(LogicalKeyboardKey.home);
          await tester.pump();
          expect(f.page, 1);
          await tester.sendKeyEvent(LogicalKeyboardKey.end);
          await tester.pump();
          expect(f.page, 10);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump();
          expect(f.page, 10);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          expect(f.page, 9);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(f.after.hasFocus, isTrue);
          await f.dispose(tester);
        },
      );
    }
    testWidgets(
      'horizontal drag reaches both page endpoints, reversed=$reversed',
      (tester) async {
        final f = _Fixture(reversed: reversed)..page = 5;
        await f.mount(tester);
        final rect = tester.getRect(find.byType(ReaderProgressSlider));
        final pointer = await tester.startGesture(rect.center);
        await pointer.moveBy(const Offset(25, 0));
        await tester.pump();
        await pointer.moveTo(Offset(rect.right - 25, rect.center.dy));
        await tester.pump();
        expect(f.page, reversed ? 1 : 10);
        await pointer.moveTo(Offset(rect.left + 25, rect.center.dy));
        await tester.pump();
        expect(f.page, reversed ? 10 : 1);
        await pointer.up();
        expect(f.calls, everyElement(inInclusiveRange(1, 10)));
        await f.dispose(tester);
      },
    );
    testWidgets(
      'assistive increments are integer image pages, reversed=$reversed',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final f = _Fixture(reversed: reversed);
        await f.mount(tester);
        final finder = find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Page',
        );
        final node = tester.getSemantics(finder);
        expect(node.getSemanticsData().value, 'Page 3 / 10');
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.increase),
          isTrue,
        );
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.increase,
            viewId: tester.view.viewId,
            nodeId: node.id,
          ),
        );
        await tester.pump();
        expect(f.page, 4);
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.decrease,
            viewId: tester.view.viewId,
            nodeId: node.id,
          ),
        );
        await tester.pump();
        expect(f.page, 3);
        f.rebuild(
          () => f.page = 11,
        ); // Comments are outside the image-page range.
        await tester.pump();
        expect(
          tester.getSemantics(finder).getSemanticsData().value,
          'Page 10 / 10',
        );
        await f.dispose(tester);
        semantics.dispose();
      },
    );
  }
  testWidgets('two-page slider selects page two past its midpoint', (
    tester,
  ) async {
    final f = _Fixture()
      ..page = 1
      ..count = 2;
    await f.mount(tester);
    final rect = tester.getRect(find.byType(ReaderProgressSlider));
    await tester.tapAt(rect.center + const Offset(30, 0));
    await tester.pump();
    expect(f.page, 2);
    await f.dispose(tester);
  });
  testWidgets(
    'one-page slider is disabled and leaves keyboard traversal available',
    (tester) async {
      final f = _Fixture()
        ..page = 1
        ..count = 1;
      await f.mount(tester);
      final rect = tester.getRect(find.byType(ReaderProgressSlider));
      expect(rect.height, greaterThanOrEqualTo(48));
      await tester.tapAt(rect.center);
      f.before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(f.after.hasFocus, isTrue);
      expect(f.calls, isEmpty);
      await f.dispose(tester);
    },
  );
}
