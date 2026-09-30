import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  late WaterfallController controller;
  late List<int> requests;
  late List<RequestScope> scopes;
  late List<Object> errors;
  late Future<List<String>> Function(int) response;
  var changes = 0;

  setUp(() {
    requests = [];
    scopes = [];
    errors = [];
    changes = 0;
    response = (chapter) async => ['$chapter-a', '$chapter-b'];
    controller =
        WaterfallController(
          maxChapter: 8,
          load: (chapter, scope) {
            requests.add(chapter);
            scopes.add(scope);
            return response(chapter);
          },
          chapterId: (chapter) => 'chapter-$chapter',
          onChanged: () => changes++,
          onPreviousError: (error, stack) => errors.add(error),
        )..initialize(
          WaterfallChapterSegment(
            chapter: 3,
            eid: 'chapter-3',
            images: ['3-a', '3-b'],
          ),
        );
  });
  tearDown(() => controller.dispose());

  test(
    'prefetch deduplicates and fills threshold across empty chapters',
    () async {
      final pending = Completer<List<String>>();
      response = (chapter) =>
          chapter == 4 ? pending.future : Future.value(['image']);
      final first = controller.ensureAfter(current: 2, threshold: 2);
      await controller.ensureAfter(current: 2, threshold: 2);
      expect(requests, [4]);
      expect(controller.loadingAfter, true);
      pending.complete([]);
      await first;
      expect(requests, [4, 5, 6]);
      expect(controller.flow.imageCount, 4);
      expect(controller.loadingAfter, false);
      expect(controller.afterError, isNull);
    },
  );

  test(
    'failed next chapter waits for explicit retry without losing flow',
    () async {
      response = (_) => Future.error(StateError('offline'));
      await controller.ensureAfter(current: 2, threshold: 1);
      await controller.ensureAfter(current: 2, threshold: 1);
      expect(requests, [4]);
      expect(controller.afterError, contains('offline'));
      expect(controller.flow.lastChapter, 3);
      response = (_) async => ['recovered'];
      controller.retryAfter();
      await controller.ensureAfter(current: 2, threshold: 1);
      expect(requests, [4, 4]);
      expect(controller.flow.lastChapter, 4);
      expect(controller.afterError, isNull);
    },
  );

  test(
    'prepend returns anchor displacement and suppresses duplicate requests',
    () async {
      final pending = Completer<List<String>>();
      response = (_) => pending.future;
      final first = controller.ensureBefore(current: 1, threshold: 1);
      expect(await controller.ensureBefore(current: 1, threshold: 1), 0);
      final images = ['2-a', '2-b', '2-c'];
      pending.complete(images);
      expect(await first, 3);
      images.clear();
      expect(controller.flow.imageRefAt(4)!.imageKey, '3-a');
      expect(controller.flow.firstChapter, 2);
      expect(requests, [2]);
      expect(
        () => controller.flow.segmentOfChapter(2)!.images.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'navigation cancels both prefetch directions and rejects late inserts',
    () async {
      final pending = <int, Completer<List<String>>>{};
      response = (chapter) => (pending[chapter] = Completer()).future;
      final after = controller.ensureAfter(current: 2, threshold: 1);
      final before = controller.ensureBefore(current: 1, threshold: 1);
      final oldScope = scopes.first;
      final navigation = controller.navigate(7);
      expect(oldScope.isCancelled, true);
      await after;
      expect(await before, 0);
      pending[7]!.complete(['7-a']);
      expect(await navigation, true);
      pending[4]!.complete(['late-next']);
      pending[2]!.completeError(StateError('late-previous'));
      await pumpEventQueue();
      expect(controller.flow.segments.map((item) => item.chapter), [7]);
      expect(controller.afterError, isNull);
      expect(errors, isEmpty);
    },
  );

  test(
    'new navigation wins and loaded chapter navigation needs no request',
    () async {
      final pending = Completer<List<String>>();
      response = (_) => pending.future;
      final old = controller.navigate(7);
      final revision = controller.revision;
      expect(await controller.navigate(3), true);
      expect(controller.revision, greaterThan(revision));
      expect(await old, false);
      pending.complete(['late']);
      await pumpEventQueue();
      expect(requests, [7]);
      expect(controller.flow.firstChapter, 3);
      expect(await controller.navigate(0), false);
      expect(await controller.navigate(9), false);
    },
  );

  test(
    'previous and navigation errors keep the existing chapter usable',
    () async {
      response = (_) => Future.error(StateError('unavailable'));
      expect(await controller.ensureBefore(current: 1, threshold: 1), 0);
      expect(errors, hasLength(1));
      await expectLater(controller.navigate(7), throwsStateError);
      expect(controller.flow.firstChapter, 3);
      response = (_) async => ['ok'];
      expect(await controller.navigate(7), true);
      expect(controller.flow.firstChapter, 7);
    },
  );

  test('dispose stops stalled work and publishes no late changes', () async {
    final pending = Completer<List<String>>();
    response = (_) => pending.future;
    final loading = controller.ensureAfter(current: 2, threshold: 1);
    final count = changes;
    controller.dispose();
    controller.dispose();
    await loading;
    expect(scopes.single.isCancelled, true);
    pending.completeError(StateError('late error'));
    await pumpEventQueue();
    controller.retryAfter();
    await controller.ensureAfter(current: 2, threshold: 1);
    expect(await controller.navigate(7), false);
    expect(changes, count);
    expect(requests, [4]);
    expect(controller.flow.lastChapter, 3);
  });
}
