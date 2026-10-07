import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_navigation.dart';

void main() {
  late ReaderChapterNavigationController controller;
  late Object target;
  late List<int> selected;
  late int changes;
  void Function()? changed;
  ReaderChapterNavigationRequest request({
    bool previous = true,
    bool next = true,
    bool reversed = false,
  }) {
    final original = target;
    return ReaderChapterNavigationRequest(
      identity: original,
      isCurrent: () => identical(target, original),
      canPrevious: previous,
      canNext: next,
      reversed: reversed,
      select: selected.add,
    );
  }

  setUp(() {
    target = Object();
    changes = 0;
    selected = [];
    changed = null;
    controller = ReaderChapterNavigationController(
      onChanged: () {
        changes++;
        changed?.call();
      },
    );
  });
  tearDown(() => controller.dispose());

  test('deduplicates reports and switches directly between chapter edges', () {
    final original = request(reversed: true);
    controller.report(original, -1);
    final first = controller.action!;
    controller.report(request(reversed: true), -1);
    expect(controller.action, same(first));
    expect(changes, 1);
    controller.report(original, 1);
    expect(controller.action!.direction, 1);
    expect(controller.action!.reversed, true);
    first.select();
    expect(selected, isEmpty);
    controller.action!.select();
    expect(selected, [1]);
    expect(controller.action, isNull);
  });

  test('retired viewport cannot show or hide replacement navigation', () {
    final old = request();
    controller.report(old, 1);
    final oldAction = controller.action!;
    target = Object();
    expect(controller.action, isNull);
    controller.report(request(), -1);
    final replacement = controller.action!;
    controller.report(old, 0);
    controller.report(old, 1);
    oldAction.select();
    expect(controller.action, same(replacement));
    expect(selected, isEmpty);
  });

  test(
    'unsupported group bounds and unknown directions never create actions',
    () {
      controller.report(request(previous: false), -1);
      controller.report(request(next: false), 1);
      controller.report(request(), 2);
      expect(controller.action, isNull);
      expect(changes, 0);
    },
  );

  test('clearing prevents reuse of an already captured action', () {
    final original = request();
    controller.report(original, -1);
    final action = controller.action!;
    controller.report(original, 0);
    action.select();
    expect(selected, isEmpty);
    controller.report(original, -1);
    final next = controller.action!;
    next.select();
    next.select();
    expect(selected, [-1]);
  });

  test('presentation reentry changing target prevents captured selection', () {
    controller.report(request(), 1);
    changed = () => target = Object();
    controller.action!.select();
    expect(selected, isEmpty);
  });

  test(
    'presentation reentry publishing another edge keeps it and rejects old dispatch',
    () {
      final original = request();
      controller.report(original, 1);
      changed = () {
        changed = null;
        controller.report(original, -1);
      };
      controller.action!.select();
      expect(controller.action!.direction, -1);
      expect(selected, isEmpty);
    },
  );

  test('disposed controller rejects reports and captured selection', () {
    final original = request();
    controller.report(original, 1);
    final action = controller.action!;
    controller.dispose();
    controller.report(original, -1);
    action.select();
    expect(controller.action, isNull);
    expect(selected, isEmpty);
  });
}
