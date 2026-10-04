import 'dart:async';
import 'dart:typed_data';

import 'images.dart';

/// A stream failure together with the errors from releasing its subscription.
/// These failures must not trigger a fallback request or a network retry.
class ImageStreamCleanupFailure implements Exception {
  ImageStreamCleanupFailure(
    Iterable<({String stage, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String stage, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image stream cleanup failed: ${failures.map((e) => '${e.stage}: ${e.error}').join('; ')}';
}

/// Consume one subscription, including cancellation while no events arrive.
/// Releasing this subscription leaves other shared download listeners intact.
Future<Uint8List?> readImageStream(
  Stream<ImageDownloadProgress> stream, {
  required Future<void> cancelSignal,
  required void Function() checkStop,
  void Function(ImageDownloadProgress)? onProgress,
}) async {
  checkStop();
  final settled = Completer<void>();
  final failures = <({String stage, Object error, StackTrace stack})>[];
  StreamSubscription<ImageDownloadProgress>? subscription;
  Uint8List? bytes;
  var finished = false;
  var cleanupFailed = false;
  void stop() {
    if (!settled.isCompleted) settled.complete();
  }

  void record(Object error, StackTrace stack) {
    if (finished) return;
    failures.add((stage: 'read', error: error, stack: stack));
    stop();
  }

  unawaited(
    cancelSignal.then((_) {
      if (finished || settled.isCompleted) return;
      try {
        checkStop();
      } catch (error, stack) {
        record(error, stack);
      }
      stop();
    }),
  );
  try {
    subscription = stream.listen(
      (event) {
        if (settled.isCompleted) return;
        try {
          checkStop();
          onProgress?.call(event);
          if (event.imageBytes != null) {
            bytes = event.imageBytes;
            stop();
          }
        } catch (error, stack) {
          record(error, stack);
        }
      },
      onError: record,
      onDone: stop,
      // StreamIterator auto-cancels on error and loses the first cancel Future.
      // Keep cancellation here, including errors and reentrant listen events.
      cancelOnError: false,
    );
  } catch (error, stack) {
    record(error, stack);
  }
  await settled.future;
  try {
    await subscription?.cancel();
  } catch (error, stack) {
    cleanupFailed = true;
    failures.add((
      stage: 'subscription cancellation',
      error: error,
      stack: stack,
    ));
  }
  finished = true;
  if (cleanupFailed || failures.length > 1) {
    Error.throwWithStackTrace(
      ImageStreamCleanupFailure(failures),
      failures.first.stack,
    );
  }
  if (failures.isNotEmpty) {
    Error.throwWithStackTrace(failures.single.error, failures.single.stack);
  }
  checkStop();
  return bytes;
}
