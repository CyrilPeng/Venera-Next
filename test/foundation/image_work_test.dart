import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_work.dart';

Future<void> _finishRead(ImageWorkTask task, Completer<int> source) async {
  try {
    await task.read(() => source.future);
  } catch (error, stack) {
    task.recordFailure(error, stack);
  } finally {
    task.finish();
  }
}

void main() {
  test(
    'resume subscriptions wait for the final hold and can detach independently',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final first = work.holdForExit();
      final second = work.holdForExit();
      var resumed = 0;
      void listener() => resumed++;
      final unsubscribe = work.addResumeListener(listener);
      final other = work.addResumeListener(listener);
      expect(resumed, 0);
      unsubscribe();
      unsubscribe();
      first();
      first();
      expect(resumed, 0);
      second();
      second();
      expect(resumed, 1);
      other();
      work.holdForExit()();
      expect(resumed, 1);
    },
  );

  test(
    'resume reentry cancels newly started work and skips removed listeners',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final release = work.holdForExit();
      void Function()? nestedRelease;
      var starts = 0;
      var lateCalls = 0;
      late void Function() unsubscribeLate;
      work.addResumeListener(() {
        late final ImageWorkTask task;
        task = work.start(
          onCancel: () {
            expect(work.start(), isNull);
            task.finish();
          },
        )!;
        if (++starts == 1) {
          nestedRelease = work.holdForExit();
          unsubscribeLate();
        } else {
          task.finish();
        }
      });
      unsubscribeLate = work.addResumeListener(() => lateCalls++);
      release();
      expect(starts, 1);
      expect(lateCalls, 0);
      expect(work.start(), isNull);
      nestedRelease!();
      expect(starts, 2);
      expect(lateCalls, 0);
    },
  );

  test(
    'a nested hold and release resumes cancelled listeners without recursion',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      var firstCalls = 0;
      var secondCalls = 0;
      var depth = 0;
      var deepest = 0;
      work.addResumeListener(() {
        depth++;
        if (depth > deepest) deepest = depth;
        firstCalls++;
        if (firstCalls == 1) work.holdForExit()();
        depth--;
      });
      work.addResumeListener(() => secondCalls++);
      work.holdForExit()();
      expect(firstCalls, 2);
      expect(secondCalls, 1);
      expect(deepest, 1);
    },
  );

  test(
    'dispose during resume prevents stale callbacks and future restoration',
    () async {
      final work = ImageWork();
      var staleCalls = 0;
      Future<void>? closing;
      work.addResumeListener(() => closing = work.dispose());
      final unsubscribe = work.addResumeListener(() => staleCalls++);
      final release = work.holdForExit();
      release();
      await closing;
      unsubscribe();
      work.addResumeListener(() => staleCalls++)();
      work.holdForExit()();
      release();
      expect(staleCalls, 0);
      expect(work.start(), isNull);
    },
  );

  test(
    'all resume errors reach the releasing owner without later replay',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final firstError = StateError('first resume');
      final secondError = StateError('second resume');
      final firstStack = StackTrace.fromString('first resume stack');
      final secondStack = StackTrace.fromString('second resume stack');
      final first = work.addResumeListener(
        () => Error.throwWithStackTrace(firstError, firstStack),
      );
      final second = work.addResumeListener(
        () => Error.throwWithStackTrace(secondError, secondStack),
      );
      var lastCalled = false;
      work.addResumeListener(() => lastCalled = true);
      final release = work.holdForExit();
      expect(
        release,
        throwsA(
          isA<ImageWorkFailure>().having(
            (error) => error.failures,
            'all resume errors and stacks',
            [
              (error: firstError, stack: firstStack),
              (error: secondError, stack: secondStack),
            ],
          ),
        ),
      );
      expect(lastCalled, isTrue);
      first();
      second();
      release();
      (await work.prepareForExit())();
    },
  );

  test('failed preparation preserves both drain and resume failures', () async {
    final work = ImageWork();
    addTearDown(work.dispose);
    final readError = StateError('read failed');
    final resumeError = StateError('resume failed');
    final readStack = StackTrace.fromString('read original stack');
    final resumeStack = StackTrace.fromString('resume original stack');
    final task = work.start()!;
    task.recordFailure(readError, readStack);
    task.finish();
    final unsubscribe = work.addResumeListener(
      () => Error.throwWithStackTrace(resumeError, resumeStack),
    );
    await expectLater(
      work.prepareForExit(),
      throwsA(
        isA<ImageWorkFailure>().having(
          (error) => error.failures,
          'drain and recovery failures',
          [
            (error: readError, stack: readStack),
            (error: resumeError, stack: resumeStack),
          ],
        ),
      ),
    );
    unsubscribe();
    final resumed = work.start();
    expect(resumed, isNotNull);
    resumed!.finish();
    (await work.prepareForExit())();
  });

  test(
    'all cancellation callbacks run once and retain their failures',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final selection = Completer<int>();
      final operation = Completer<void>();
      final selectionError = StateError('selection cancellation');
      final operationError = StateError('operation cancellation');
      final selectionStack = StackTrace.fromString('selection original stack');
      final operationStack = StackTrace.fromString('operation original stack');
      var selectionCalls = 0;
      var operationCalls = 0;
      final task = work.start(
        cancelSelection: () {
          selectionCalls++;
          Error.throwWithStackTrace(selectionError, selectionStack);
        },
        onCancel: () {
          operationCalls++;
          operation.complete();
          Error.throwWithStackTrace(operationError, operationStack);
        },
      )!;
      final selecting = expectLater(
        task.select(() => selection.future),
        throwsA(isA<ImageWorkTaskCancelled>()),
      );
      var drained = false;
      final preparing = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>()
              .having((e) => e.failures, 'independent cancellation failures', [
                (error: selectionError, stack: selectionStack),
                (error: operationError, stack: operationStack),
              ]),
        ),
      ).then((_) => drained = true);
      task.cancel();
      await operation.future;
      await pumpEventQueue();
      expect(selectionCalls, 1);
      expect(operationCalls, 1);
      expect(drained, isFalse);
      selection.complete(1);
      await selecting;
      task.finish();
      await preparing;
    },
  );

  test(
    'selection cancellation runs once and independent holds compose',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final selected = Completer<int>();
      var overlayOpen = true;
      var cancellations = 0;
      final task = work.start(
        cancelSelection: () {
          cancellations++;
          overlayOpen = false;
          selected.complete(1);
        },
      )!;
      final selecting = expectLater(
        task.select(() => selected.future),
        throwsA(isA<ImageWorkTaskCancelled>()),
      );
      final firstRelease = work.holdForExit();
      final secondRelease = work.holdForExit();
      expect(overlayOpen, isFalse);
      expect(cancellations, 1);
      expect(task.isCancelled, isTrue);
      expect(work.start(), isNull);
      await selecting;
      task.finish();
      firstRelease();
      firstRelease();
      expect(work.start(), isNull);
      secondRelease();
      final retry = work.start();
      expect(retry, isNotNull);
      expect(retry!.isCancelled, isFalse);
      retry.finish();
    },
  );

  test(
    'cancelled read and task completion wait for the original future',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final source = Completer<int>();
      final task = work.start()!;
      var readFinished = false;
      var taskFinished = false;
      var prepared = false;
      final reading = expectLater(
        task.read(() => source.future),
        throwsA(isA<ImageWorkTaskCancelled>()),
      ).then((_) => readFinished = true);
      final done = task.done.then((_) => taskFinished = true);
      final preparation = work.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      await pumpEventQueue();
      expect(readFinished, isFalse);
      expect(taskFinished, isFalse);
      expect(prepared, isFalse);
      source.complete(42);
      await reading;
      expect(taskFinished, isFalse);
      expect(prepared, isFalse);
      task.finish();
      task.finish();
      await done;
      (await preparation)();
    },
  );

  test(
    'exit drains every task before reporting all retained failures',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final sources = List.generate(3, (_) => Completer<int>());
      final tasks = List.generate(3, (_) => work.start()!);
      final jobs = List.generate(3, (i) => _finishRead(tasks[i], sources[i]));
      final firstError = StateError('first read');
      final lastError = StateError('last read');
      final firstStack = StackTrace.fromString('first read original stack');
      final lastStack = StackTrace.fromString('last read original stack');
      var drained = false;
      final expected = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'both failures and original stacks',
            [
              (error: firstError, stack: firstStack),
              (error: lastError, stack: lastStack),
            ],
          ),
        ),
      ).then((_) => drained = true);
      expect(tasks.every((task) => task.isCancelled), isTrue);
      sources[0].completeError(firstError, firstStack);
      await jobs[0];
      sources[1].complete(2);
      await jobs[1];
      await pumpEventQueue();
      expect(drained, isFalse);
      sources[2].completeError(lastError, lastStack);
      await jobs[2];
      await expected;
      // Failed preparation releases its hold and consumes the recorded failures.
      final retry = work.start();
      expect(retry, isNotNull);
      retry!.finish();
      (await work.prepareForExit())();
    },
  );

  test('dispose is idempotent and retains late failure and stack', () async {
    final work = ImageWork();
    final source = Completer<int>();
    final task = work.start()!;
    final job = _finishRead(task, source);
    final failure = StateError('late disposal read');
    final stack = StackTrace.fromString('late disposal original stack');
    var closed = false;
    final closing = work.dispose();
    final expected = expectLater(
      closing,
      throwsA(
        isA<ImageWorkFailure>().having((e) => e.failures, 'late failure', [
          (error: failure, stack: stack),
        ]),
      ),
    ).then((_) => closed = true);
    expect(work.dispose(), same(closing));
    expect(work.start(), isNull);
    await pumpEventQueue();
    expect(closed, isFalse);
    source.completeError(failure, stack);
    await job;
    await expected;
    expect(work.start(), isNull);
    expect(work.dispose(), same(closing));
  });

  test(
    'failed preparation releases only its own hold and retry can resume',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final task = work.start()!;
      final releaseOuter = work.holdForExit();
      final failure = StateError('retained after old widget disappeared');
      final stack = StackTrace.fromString('old widget original stack');
      task.recordFailure(failure, stack);
      task.finish();
      await expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'retained failure',
            [(error: failure, stack: stack)],
          ),
        ),
      );
      expect(work.start(), isNull);
      releaseOuter();
      final retry = work.start()!;
      expect(await retry.read(() async => 7), 7);
      retry.finish();
      final release = await work.prepareForExit();
      expect(work.start(), isNull);
      release();
    },
  );

  test('owners do not share cancellation, admission, or failures', () async {
    final first = ImageWork();
    final second = ImageWork();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstSource = Completer<int>();
    final secondSource = Completer<int>();
    final firstTask = first.start()!;
    final secondTask = second.start()!;
    final firstJob = _finishRead(firstTask, firstSource);
    final secondRead = secondTask.read(() => secondSource.future);
    final failure = StateError('first owner only');
    final expectation = expectLater(
      first.prepareForExit(),
      throwsA(
        isA<ImageWorkFailure>().having(
          (e) => e.failures.single.error,
          'first owner failure',
          same(failure),
        ),
      ),
    );
    expect(firstTask.isCancelled, isTrue);
    expect(secondTask.isCancelled, isFalse);
    final additionalTask = second.start();
    expect(additionalTask, isNotNull);
    additionalTask!.finish();
    firstSource.completeError(failure);
    await firstJob;
    await expectation;
    secondSource.complete(9);
    expect(await secondRead, 9);
    secondTask.finish();
    (await second.prepareForExit())();
  });

  test(
    'selection cancellation callback failure is retained until selection ends',
    () async {
      final work = ImageWork();
      addTearDown(work.dispose);
      final source = Completer<int>();
      final failure = StateError('overlay cancellation');
      final stack = StackTrace.fromString(
        'overlay cancellation original stack',
      );
      final task = work.start(
        cancelSelection: () {
          Error.throwWithStackTrace(failure, stack);
        },
      )!;
      final selection = expectLater(
        task.select(() => source.future),
        throwsA(isA<ImageWorkTaskCancelled>()),
      );
      var drained = false;
      final expectation = expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'cancellation callback failure',
            [(error: failure, stack: stack)],
          ),
        ),
      ).then((_) => drained = true);
      await pumpEventQueue();
      expect(drained, isFalse);
      source.complete(0);
      await selection;
      task.finish();
      await expectation;
    },
  );
}
