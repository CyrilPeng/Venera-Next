import 'dart:async';

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
  bool _started = false;
  bool isClosed = false;

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
            onDone: _finish,
          );
        } catch (error, stack) {
          controller.addError(error, stack);
          _finish();
        }
      },
      onCancel: () {
        _controllers.remove(controller);
        if (_controllers.isEmpty) cancel();
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

  void cancel() {
    if (isClosed) return;
    // Signal HTTP/source work before waiting for an async generator to unwind.
    _scope.cancel();
    final subscription = _subscription;
    _finish();
    // An async generator can surface its interrupted await as a cancellation
    // future error. There are no consumers left to receive that terminal error.
    if (subscription != null) subscription.cancel().ignore();
  }
}
