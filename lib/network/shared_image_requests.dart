import 'dart:async';

import 'request_scope.dart';
import 'shared_request_stream.dart';

/// Tracks both reusable image streams and retired streams still unwinding.
/// A missing key creates an independent request with the same shutdown lifetime.
class SharedImageRequests<T> {
  final _active = <Object, SharedRequestStream<T>>{};
  final _pending = Set<SharedRequestStream<T>>.identity();
  final _failures = <({Object error, StackTrace stack})>[];
  final _holds = <Object>{};
  Future<void>? _draining;

  Stream<T> open(Stream<T> Function(RequestScope scope) source, {Object? key}) {
    if (_holds.isNotEmpty) return Stream<T>.error(const RequestCancelled());
    if (key != null) {
      final current = _active[key];
      if (current != null && !current.isClosed) return current.stream;
    }
    final request = SharedRequestStream<T>(source, (finished) {
      // A retired request must never erase its replacement under the same key.
      if (key != null && identical(_active[key], finished)) {
        _active.remove(key);
      }
    });
    if (key != null) _active[key] = request;
    _pending.add(request);
    unawaited(
      request.done.then<void>(
        (_) => _pending.remove(request),
        onError: (Object error, StackTrace stack) {
          _pending.remove(request);
          // The caller may already have released its subscription without
          // awaiting cancellation. Retain cleanup failures for the next drain.
          _failures.add((error: error, stack: stack));
        },
      ),
    );
    return request.stream;
  }

  /// Stop currently registered work, including retired requests. Later opens
  /// remain allowed unless a preparation hold is active.
  Future<void> cancelAll() {
    final completion = Completer<void>();
    final previous = _draining;
    // Each call includes requests accepted since an earlier cancellation began.
    final requests = _pending.toList();
    _draining = completion.future;
    unawaited(completion.future.then<void>((_) {}, onError: (Object _) {}));
    for (final request in requests) {
      unawaited(request.cancel());
    }
    unawaited(() async {
      final failures = <({Object error, StackTrace stack})>[];
      if (previous != null) {
        try {
          await previous;
        } on SharedImageRequestFailure catch (error) {
          failures.addAll(error.failures);
        }
      }
      await Future.wait([
        for (final request in requests)
          request.done.then<void>((_) {}, onError: (Object _) {}),
      ]);
      failures.addAll(_failures);
      _failures.clear();
      if (identical(_draining, completion.future)) _draining = null;
      if (failures.isEmpty) {
        completion.complete();
      } else {
        completion.completeError(SharedImageRequestFailure(failures));
      }
    }());
    return completion.future;
  }

  /// Freeze admission synchronously; each caller owns an independent hold.
  /// Cancelled work is not restarted, but releasing all holds permits retries.
  Future<void Function()> prepareForExit() async {
    final hold = Object();
    _holds.add(hold);
    try {
      await cancelAll();
    } catch (_) {
      _holds.remove(hold);
      rethrow;
    }
    return () => _holds.remove(hold);
  }
}

class SharedImageRequestFailure implements Exception {
  SharedImageRequestFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image request cleanup failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
}
