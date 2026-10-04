import 'dart:async';

import 'package:dio/dio.dart';

import 'request_scope.dart';

/// One independent request shared by active stream subscribers.
/// Merely obtaining a stream does not start or retain the request.
class SharedRequestStream<T> {
  SharedRequestStream(this._source, this.onClosed);

  final Stream<T> Function(RequestScope scope) _source;
  final void Function(SharedRequestStream<T>) onClosed;
  final _scope = RequestScope();
  final _controllers = <StreamController<T>>{};
  StreamSubscription<T>? _subscription;
  final _done = Completer<void>();
  bool _started = false;
  bool isClosed = false;

  /// Actual source-stream completion, including asynchronous cancellation.
  /// Closed admission alone does not mean the source has finished unwinding.
  Future<void> get done => _done.future;

  Stream<T> get stream {
    late StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        if (isClosed) {
          unawaited(controller.close());
          return;
        }
        _controllers.add(controller);
        if (_started) return;
        _started = true;
        try {
          _subscription = _source(_scope).listen(
            (event) {
              if (isClosed) return;
              for (final listener in _controllers.toList()) {
                listener.add(event);
              }
            },
            onError: (Object error, StackTrace stack) {
              if (isClosed) return;
              for (final listener in _controllers.toList()) {
                listener.addError(error, stack);
              }
            },
            onDone: () {
              _finish();
              if (!_done.isCompleted) _done.complete();
            },
          );
        } catch (error, stack) {
          controller.addError(error, stack);
          _finish();
          if (!_done.isCompleted) _done.complete();
        }
      },
      onCancel: () {
        // Final closure already removed these listeners and owns the source
        // cancellation wait. Returning its failing Future from automatic
        // controller closure would report a second, unhandled async error.
        if (!_controllers.remove(controller)) return null;
        if (_controllers.isEmpty) return cancel();
      },
    );
    return controller.stream;
  }

  void _finish() {
    if (isClosed) return;
    isClosed = true;
    _scope.dispose();
    _subscription = null;
    final listeners = _controllers.toList();
    _controllers.clear();
    for (final listener in listeners) {
      unawaited(listener.close());
    }
    onClosed(this);
  }

  Future<void> cancel() {
    if (isClosed) return done;
    // Signal HTTP/source work before waiting for an async generator to unwind.
    _scope.cancel();
    final subscription = _subscription;
    _finish();
    // Observe ignored calls too; awaiting callers still receive cleanup errors.
    done.ignore();
    _done.complete(_cancelSource(subscription));
    return done;
  }

  Future<void> _cancelSource(StreamSubscription<T>? subscription) async {
    try {
      await subscription?.cancel();
    } on RequestCancelled {
      // The source may surface the cooperative stop while unwinding.
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) rethrow;
    }
  }
}
