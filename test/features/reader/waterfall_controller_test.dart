import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  late WaterfallController controller;
  late ImageWork work;
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
    work = ImageWork();
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
          imageWork: work,
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

  test('prepare waits for both original calls after UI cancellation', () async {
    final next = Completer<List<String>>();
    final previous = Completer<List<String>>();
    response = (chapter) => chapter == 4 ? next.future : previous.future;
    final after = controller.ensureAfter(current: 2, threshold: 1);
    final before = controller.ensureBefore(current: 1, threshold: 1);
    var prepared = false;
    final preparing = work.prepareForExit().then((release) {
      prepared = true;
      return release;
    });

    await after;
    expect(await before, 0);
    expect(scopes.every((scope) => scope.isCancelled), true);
    expect(controller.loadingAfter, false);
    expect(controller.afterError, isNull);
    expect(errors, isEmpty);
    expect(prepared, false);
    next.complete(['late next']);
    await pumpEventQueue();
    expect(prepared, false);
    final changedAfterCancellation = changes;
    previous.complete(['late previous']);
    final release = await preparing;
    expect(changes, changedAfterCancellation);
    expect(controller.flow.segments.map((segment) => segment.chapter), [3]);

    release();
    response = (_) async => ['resumed'];
    await controller.ensureAfter(current: 2, threshold: 1);
    expect(controller.flow.lastChapter, 4);
    expect(controller.afterError, isNull);
  });

  test(
    'held work refuses requests and can resume every loading direction',
    () async {
      final release = work.holdForExit();
      await controller.ensureAfter(current: 2, threshold: 1);
      expect(await controller.ensureBefore(current: 1, threshold: 1), 0);
      expect(await controller.navigate(7), false);
      expect(requests, isEmpty);
      expect(controller.loadingAfter, false);
      expect(controller.afterError, isNull);
      expect(errors, isEmpty);

      release();
      expect(await controller.ensureBefore(current: 1, threshold: 1), 2);
      await controller.ensureAfter(current: 4, threshold: 1);
      expect(await controller.navigate(7), true);
      expect(requests, [2, 4, 7]);
    },
  );

  test(
    'late original failure reaches preparation with its original stack',
    () async {
      final pending = Completer<List<String>>();
      final failure = StateError('late source failure');
      final stack = StackTrace.fromString('original source stack');
      response = (_) => pending.future;
      final loading = controller.ensureAfter(current: 2, threshold: 1);
      final failedPreparation = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures,
            'original failure',
            [(error: failure, stack: stack)],
          ),
        ),
      );
      await loading;
      pending.completeError(failure, stack);
      await failedPreparation;
      expect(controller.afterError, isNull);
      expect(errors, isEmpty);

      response = (_) async => ['recovered'];
      expect(await controller.navigate(7), true);
      final release = await work.prepareForExit();
      release();
    },
  );

  test(
    'replacement keeps retired requests owned until every original ends',
    () async {
      final pending = <int, Completer<List<String>>>{};
      response = (chapter) => (pending[chapter] = Completer()).future;
      final after = controller.ensureAfter(current: 2, threshold: 1);
      final firstNavigation = controller.navigate(6);
      final replacement = controller.navigate(7);
      await after;
      expect(await firstNavigation, false);
      pending[7]!.complete(['current']);
      expect(await replacement, true);

      var prepared = false;
      final preparing = work.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      pending[6]!.complete(['retired navigation']);
      await pumpEventQueue();
      expect(prepared, false);
      pending[4]!.complete(['retired prefetch']);
      final release = await preparing;
      expect(controller.flow.segments.map((segment) => segment.chapter), [7]);
      release();
    },
  );

  test(
    'failure of retired navigation is owned even before prepare starts',
    () async {
      final pending = Completer<List<String>>();
      final failure = StateError('retired failure');
      response = (_) => pending.future;
      final retired = controller.navigate(7);
      expect(await controller.navigate(3), true);
      expect(await retired, false);
      pending.completeError(failure);
      await pumpEventQueue();
      await expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures.map((entry) => entry.error),
            'retired error',
            [failure],
          ),
        ),
      );
      expect(errors, isEmpty);
      expect(controller.flow.firstChapter, 3);
    },
  );

  test(
    'dispose shares a join for originals without closing shared work',
    () async {
      final retired = Completer<List<String>>();
      final active = Completer<List<String>>();
      response = (chapter) => chapter == 4 ? retired.future : active.future;
      final loading = controller.ensureAfter(current: 2, threshold: 1);
      final navigation = controller.navigate(7);
      final disposal = controller.dispose();
      expect(identical(disposal, controller.dispose()), true);
      var disposed = false;
      unawaited(disposal.then((_) => disposed = true));
      await loading;
      expect(await navigation, false);
      active.complete(['late current']);
      await pumpEventQueue();
      expect(disposed, false);
      retired.complete(['late retired']);
      await disposal;
      expect(disposed, true);

      final otherOwnerTask = work.start();
      expect(otherOwnerTask, isNotNull);
      otherOwnerTask!.finish();
      final release = await work.prepareForExit();
      release();
    },
  );

  test(
    'ordinary source failures stay on the existing UI error paths',
    () async {
      final failure = StateError('ordinary failure');
      response = (_) => Future.error(failure);
      await controller.ensureAfter(current: 2, threshold: 1);
      expect(controller.afterError, contains('ordinary failure'));
      expect(await controller.ensureBefore(current: 1, threshold: 1), 0);
      expect(errors, [failure]);
      await expectLater(controller.navigate(7), throwsA(same(failure)));
      final release = await work.prepareForExit();
      release();
    },
  );

  for (final cancellation in [
    const RequestCancelled(),
    DioException(
      requestOptions: RequestOptions(path: '/chapter'),
      type: DioExceptionType.cancel,
    ),
  ]) {
    test('late ${cancellation.runtimeType} cancellation is expected', () async {
      final pending = Completer<List<String>>();
      response = (_) => pending.future;
      final loading = controller.ensureAfter(current: 2, threshold: 1);
      final preparing = work.prepareForExit();
      await loading;
      pending.completeError(cancellation);
      final release = await preparing;
      expect(controller.afterError, isNull);
      release();
    });
  }

  test(
    'reentrant hold retains synchronous source failure and request zone',
    () async {
      final failure = StateError('synchronous source failure');
      late void Function() release;
      response = (_) {
        expect(RequestScope.current, same(scopes.single));
        release = work.holdForExit();
        throw failure;
      };
      await controller.ensureAfter(current: 2, threshold: 1);
      expect(controller.afterError, isNull);
      await expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures.map((entry) => entry.error),
            'synchronous error',
            [failure],
          ),
        ),
      );
      release();
      response = (_) async => ['recovered'];
      expect(await controller.navigate(7), true);
    },
  );
}
