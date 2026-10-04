import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  for (final outcome in ['bytes', 'error', 'cancel']) {
    test(
      '$outcome waits for the first cancellation and retains cleanup errors',
      () async {
        final scope = RequestScope();
        final release = Completer<void>();
        final readError = StateError('original read');
        final readStack = StackTrace.fromString('original read stack');
        final cleanupError = StateError('original cleanup');
        final cleanupStack = StackTrace.fromString('original cleanup stack');
        var cancellations = 0;
        var completed = false;
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            cancellations++;
            return release.future;
          },
        );
        final result = readImageStream(
          source.stream,
          cancelSignal: scope.whenCancelled,
          checkStop: scope.check,
        );
        final expected = expectLater(
          result,
          throwsA(
            isA<ImageStreamCleanupFailure>().having(
              (failure) {
                if (outcome == 'error') {
                  expect(failure.failures.first.error, same(readError));
                  expect(failure.failures.first.stack, same(readStack));
                }
                return failure.failures.last;
              },
              'original cleanup failure',
              (
                stage: 'subscription cancellation',
                error: cleanupError,
                stack: cleanupStack,
              ),
            ),
          ),
        ).then((_) => completed = true);
        if (outcome == 'error') {
          source.addError(readError, readStack);
        } else if (outcome == 'cancel') {
          scope.cancel();
        } else {
          source.add(
            ImageDownloadProgress(
              currentBytes: 1,
              totalBytes: 1,
              imageBytes: Uint8List.fromList([1]),
            ),
          );
        }
        await pumpEventQueue();
        expect(cancellations, 1);
        expect(completed, isFalse);
        scope.cancel();
        release.completeError(cleanupError, cleanupStack);
        await expected;
        expect(cancellations, 1);
        await source.close();
        scope.dispose();
      },
    );
  }

  test(
    'a pending source failure survives cancellation during release',
    () async {
      final scope = RequestScope();
      final release = Completer<void>();
      final error = StateError('source failure before cancellation');
      final stack = StackTrace.fromString('source original stack');
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => release.future,
      );
      final reading = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
      Object? observed;
      StackTrace? observedStack;
      final expected = reading.then<void>(
        (_) => fail('should fail'),
        onError: (Object e, StackTrace s) {
          observed = e;
          observedStack = s;
        },
      );
      source.addError(error, stack);
      await pumpEventQueue();
      scope.cancel();
      release.complete();
      await expected;
      expect(observed, same(error));
      expect(observedStack, same(stack));
      await source.close();
      scope.dispose();
    },
  );

  test(
    'cancels a stalled subscription without waiting for another event',
    () async {
      final scope = RequestScope();
      var cancelled = false;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled = true,
      );
      final result = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
      final expectation = expectLater(result, throwsA(isA<RequestCancelled>()));
      scope.cancel();
      await expectation;
      expect(cancelled, true);
      await source.close();
      scope.dispose();
    },
  );

  test(
    'returns final bytes and unsubscribes after reporting progress',
    () async {
      final scope = RequestScope();
      var cancelled = false;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled = true,
      );
      final progress = <int>[];
      final result = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
        onProgress: (event) => progress.add(event.currentBytes),
      );
      final bytes = Uint8List.fromList([1, 2]);
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      source.add(
        ImageDownloadProgress(
          currentBytes: 2,
          totalBytes: 2,
          imageBytes: bytes,
        ),
      );
      expect(await result, same(bytes));
      expect(progress, [1, 2]);
      expect(cancelled, true);
      await source.close();
      scope.dispose();
    },
  );

  test(
    'propagates errors and does not publish queued events after cancellation',
    () async {
      final scope = RequestScope();
      final failed = readImageStream(
        Stream.error(StateError('offline')),
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
      );
      await expectLater(failed, throwsStateError);
      final source = StreamController<ImageDownloadProgress>();
      var notified = false;
      final pending = readImageStream(
        source.stream,
        cancelSignal: scope.whenCancelled,
        checkStop: scope.check,
        onProgress: (_) => notified = true,
      );
      final expectation = expectLater(
        pending,
        throwsA(isA<RequestCancelled>()),
      );
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      scope.cancel();
      await expectation;
      expect(notified, false);
      await source.close();
      scope.dispose();
    },
  );
}
