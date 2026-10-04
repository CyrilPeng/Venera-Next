import 'dart:async';

import 'app_dio.dart';

/// Owns one image attempt, including native work after Dio returns cancellation.
class ImageHttpClient {
  ImageHttpClient(this.dio) : _adapter = dio.httpClientAdapter;

  final Dio dio;
  final HttpClientAdapter _adapter;
  Future<void>? _closing;

  Stream<T> run<T>(Stream<T> Function(Dio dio) action) async* {
    Object? cause;
    StackTrace? stack;
    try {
      // await-for turns stream errors into caught failures. yield* would forward
      // the original error before cleanup and bypass this cause aggregation.
      await for (final event in action(dio)) {
        yield event;
      }
    } catch (error, trace) {
      cause = error;
      stack = trace;
      rethrow;
    } finally {
      await close(cause: cause, stackTrace: stack);
    }
  }

  Future<void> close({Object? cause, StackTrace? stackTrace}) =>
      _closing ??= _close(cause, stackTrace);

  Future<void> _close(Object? cause, StackTrace? stackTrace) async {
    final failures = <RHttpCleanupError>[];
    Future<void> release(String stage, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        if (error is RHttpCleanupFailure) {
          failures.addAll(error.failures);
        } else {
          failures.add((stage: stage, error: error, stack: stack));
        }
      }
    }

    await release('close image HTTP client', () => dio.close(force: true));
    final adapter = _adapter;
    if (adapter is RHttpAdapter) {
      await release('drain image native request', adapter.waitForIdle);
    }
    if (failures.isNotEmpty) {
      throw ImageHttpCleanupFailure(
        cause: cause,
        stackTrace: stackTrace,
        failures: failures,
      );
    }
  }
}

class ImageHttpCleanupFailure implements Exception {
  ImageHttpCleanupFailure({
    required this.cause,
    required this.stackTrace,
    required Iterable<RHttpCleanupError> failures,
  }) : failures = List.unmodifiable(failures);

  final Object? cause;
  final StackTrace? stackTrace;
  final List<RHttpCleanupError> failures;

  @override
  String toString() =>
      '${cause == null ? '' : '$cause; '}Image HTTP cleanup failed: '
      '${failures.map((failure) => '${failure.stage}: ${failure.error}').join('; ')}';
}
