import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/reader/image_favorite_controller.dart';
import 'package:venera_next/foundation/image_work.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late ImageWork work;
  late ReaderImageFavoriteController controller;
  late List<ImageFavoriteResult> results;
  late List<(Object, StackTrace)> errors;
  var reads = 0, writes = 0, updates = 0, unsupported = 0, cancelled = 0;
  var current = true;
  Future<bool> Function()? read;
  Future<ImageFavoriteResult> Function()? write;
  void Function()? report;

  ReaderImageFavoriteQuery query([Object key = 'first']) =>
      ReaderImageFavoriteQuery(
        key: key,
        isCurrent: () => current,
        read: () {
          reads++;
          return read?.call() ?? Future.value(false);
        },
      );
  ReaderImageFavoriteRequest request({bool supported = true}) =>
      ReaderImageFavoriteRequest(
        supported: supported,
        isCurrent: () => current,
        toggle: (index, check) {
          check();
          writes++;
          return write?.call() ?? Future.value(ImageFavoriteResult.collected);
        },
      );
  Future<void> ready() async {
    controller.bind(query());
    await settle();
  }

  setUp(() {
    work = ImageWork();
    results = [];
    errors = [];
    reads = writes = updates = unsupported = cancelled = 0;
    current = true;
    read = null;
    write = null;
    report = null;
    controller = ReaderImageFavoriteController(
      work: work,
      onChanged: () => updates++,
      onResult: results.add,
      onUnsupported: () => unsupported++,
      onError: (error, stack) {
        errors.add((error, stack));
        report?.call();
      },
      cancelSelection: () => cancelled++,
    );
  });
  tearDown(() async {
    await controller.dispose();
    await work.dispose();
  });

  test(
    'same key does not reuse a query whose captured layout is retired',
    () async {
      var oldCurrent = true;
      final oldRead = Completer<bool>();
      controller.bind(
        ReaderImageFavoriteQuery(
          key: 'same',
          read: () => oldRead.future,
          isCurrent: () => oldCurrent,
        ),
      );
      oldCurrent = false;
      controller.bind(
        ReaderImageFavoriteQuery(
          key: 'same',
          read: () async => true,
          isCurrent: () => true,
        ),
      );
      await settle();
      oldRead.complete(false);
      await settle();
      expect(controller.status, ReaderImageFavoriteStatus.collected);
    },
  );

  test(
    'ambiguous spread allows selection without claiming an image is uncollected',
    () async {
      controller.bind(
        ReaderImageFavoriteQuery(
          key: 'spread',
          read: () async => null,
          isCurrent: () => true,
        ),
      );
      await settle();
      expect(controller.status, ReaderImageFavoriteStatus.selectImage);
      expect(controller.canCollect, isTrue);
      await controller.collect(request(), () async => 1);
      expect(writes, 1);
      expect(results, [ImageFavoriteResult.collected]);
    },
  );

  test(
    'failure retains diagnostics and repeated retry only rereads status',
    () async {
      final failure = StateError('query failed');
      final stack = StackTrace.current;
      read = () => Future.error(failure, stack);
      await ready();
      expect(controller.status, ReaderImageFavoriteStatus.failed);
      expect(controller.error, same(failure));
      expect(controller.errorStack, same(stack));
      expect(controller.canCollect, isFalse);
      final pending = Completer<bool>();
      read = () => pending.future;
      controller.retry();
      controller.retry();
      expect(reads, 2);
      pending.complete(true);
      await settle();
      expect(controller.status, ReaderImageFavoriteStatus.collected);
      expect(controller.error, isNull);
      expect(writes, 0);
    },
  );

  test(
    'identical builds cache reads and notifications wait for the next build',
    () async {
      await ready();
      controller.bind(query());
      expect(reads, 1);
      controller.invalidate();
      controller.invalidate();
      expect(reads, 1);
      controller.bind(query());
      await settle();
      expect(reads, 2);
      controller.bind(null);
      expect(controller.status, ReaderImageFavoriteStatus.unavailable);
    },
  );

  for (final fail in [false, true]) {
    test('retired query cannot overwrite new content, failure=$fail', () async {
      final old = Completer<bool>();
      read = () => old.future;
      controller.bind(query());
      read = () async => true;
      controller.bind(query('next'));
      await settle();
      final count = updates;
      if (fail) {
        old.completeError(StateError('old'));
      } else {
        old.complete(false);
      }
      await settle();
      expect(controller.status, ReaderImageFavoriteStatus.collected);
      expect(updates, count);
      expect(errors, isEmpty);
    });
  }

  test(
    'detached reads remain owned until their actual failure is consumed',
    () async {
      final pending = Completer<bool>();
      read = () => pending.future;
      controller.bind(query());
      var finished = false;
      final closing = controller.dispose().then((_) => finished = true);
      final owner = work.dispose();
      await settle();
      expect(finished, isFalse);
      pending.completeError(StateError('read failed after removal'));
      await Future.wait([closing, owner]);
      expect(finished, isTrue);
      expect(errors, isEmpty);
    },
  );

  test(
    'registration reentering close rejects reads before calling storage',
    () async {
      Future<void>? closing;
      work.retainTasks((_) {
        closing = work.dispose();
        return () {};
      });
      controller.bind(query());
      await closing;
      expect(reads, 0);
      expect(controller.status, ReaderImageFavoriteStatus.unavailable);
    },
  );

  test(
    'reversible exit holds reject work and resume refreshes status',
    () async {
      await ready();
      final release = await work.prepareForExit();
      controller.refresh();
      expect(controller.status, ReaderImageFavoriteStatus.unavailable);
      await controller.collect(request(), () async => 1);
      expect(writes, 0);
      release();
      await settle();
      expect(reads, 2);
      expect(controller.canCollect, isTrue);
    },
  );

  test('duplicate collection taps select and commit exactly once', () async {
    await ready();
    final selection = Completer<int?>();
    var picks = 0;
    Future<int?> pick() {
      picks++;
      return selection.future;
    }

    final first = controller.collect(request(), pick);
    await controller.collect(request(), pick);
    expect(controller.collecting, isTrue);
    selection.complete(2);
    await first;
    expect(picks, 1);
    expect(writes, 1);
    expect(results, [ImageFavoriteResult.collected]);
  });

  test(
    'content retirement during selection prevents writes and feedback',
    () async {
      await ready();
      final selection = Completer<int?>();
      final collecting = controller.collect(request(), () => selection.future);
      current = false;
      selection.complete(1);
      await collecting;
      expect(writes, 0);
      expect(results, isEmpty);
      expect(errors, isEmpty);
    },
  );

  test(
    'local images report unsupported without starting selection or storage',
    () async {
      await ready();
      await controller.collect(
        request(supported: false),
        () => throw StateError('unexpected picker'),
      );
      expect(unsupported, 1);
      expect(writes, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'disposal cancels selection and retains the pending selection future',
    () async {
      await ready();
      final selection = Completer<int?>();
      final collecting = controller.collect(request(), () => selection.future);
      var closed = false;
      final closing = controller.dispose().then((_) => closed = true);
      await settle();
      expect(cancelled, 1);
      expect(closed, isFalse);
      selection.complete(1);
      await Future.wait([closing, collecting]);
      expect(writes, 0);
    },
  );

  test(
    'late write failure stays on the original task and blocks owner close',
    () async {
      await ready();
      final pending = Completer<ImageFavoriteResult>();
      write = () => pending.future;
      final collecting = controller.collect(request(), () async => 1);
      await settle();
      final closing = work.dispose();
      final failure = StateError('late write');
      final stack = StackTrace.current;
      final checkClose = expectLater(
        closing,
        throwsA(
          isA<ImageWorkFailure>()
              .having(
                (error) => error.failures.single.error,
                'original failure',
                same(failure),
              )
              .having(
                (error) => error.failures.single.stack,
                'original stack',
                same(stack),
              ),
        ),
      );
      pending.completeError(failure, stack);
      await collecting;
      await checkClose;
      expect(results, isEmpty);
      expect(writes, 1);
      // The same failed final close is intentionally stable.
      await expectLater(work.dispose(), throwsA(isA<ImageWorkFailure>()));
      work = ImageWork();
    },
  );

  test(
    'write failure and reporter failure both retain original diagnostics',
    () async {
      await ready();
      final failure = StateError('write');
      final reporting = StateError('report');
      write = () async => throw failure;
      report = () => throw reporting;
      await controller.collect(request(), () async => 1);
      await expectLater(
        work.dispose(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures.map((entry) => entry.error).toList(),
            'failures',
            [failure, reporting],
          ),
        ),
      );
      work = ImageWork();
      expect(writes, 1);
    },
  );

  test(
    'failed toggle reconciles by reading and is never automatically replayed',
    () async {
      await ready();
      write = () async {
        read = () async => true;
        throw StateError('committed; cleanup failed');
      };
      await controller.collect(request(), () async => 1);
      await settle();
      controller.retry();
      expect(controller.status, ReaderImageFavoriteStatus.collected);
      expect(writes, 1);
      expect(errors, hasLength(1));
    },
  );
}
