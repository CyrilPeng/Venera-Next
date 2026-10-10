import 'dart:async';

import 'package:dio/dio.dart';
import 'package:venera_next/foundation/operation_failure.dart';

class RequestCancelled extends OperationFailure {
  const RequestCancelled()
    : super(message: 'Request cancelled', kind: FailureKind.cancelled);
}

/// Cooperative lifetime for a source call, its retries and HTTP requests.
class RequestScope {
  RequestScope({RequestScope? parent, Duration? timeout}) : _parent = parent {
    parent?._children.add(this);
    if (parent?.isCancelled == true) cancel(parent!._reason);
    if (timeout != null && !isCancelled) {
      _timer = Timer(
        timeout,
        () => cancel(TimeoutException('Source call timed out', timeout)),
      );
    }
  }

  static final Object _zoneKey = Object();
  static RequestScope? get current => Zone.current[_zoneKey] as RequestScope?;
  final RequestScope? _parent;
  final _children = <RequestScope>{};
  final _cancelled = Completer<void>();
  final cancelToken = CancelToken();
  Timer? _timer;
  Object _reason = const RequestCancelled();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel([Object? reason]) {
    if (isCancelled) return;
    _reason = reason ?? const RequestCancelled();
    _timer?.cancel();
    cancelToken.cancel(_reason);
    _cancelled.complete();
    for (final child in _children.toList()) {
      child.cancel(_reason);
    }
  }

  void check() {
    if (isCancelled) throw _reason;
  }

  Future<T> run<T>(FutureOr<T> Function() action) async {
    check();
    final result = await Future.any<T>([
      runZoned(() => Future<T>.sync(action), zoneValues: {_zoneKey: this}),
      whenCancelled.then<T>((_) => throw _reason),
    ]);
    check();
    return result;
  }

  /// Propagates cancellation immediately, but joins the accepted action before
  /// completing. Its failure remains observable even if cancellation came first.
  Future<T> runToCompletion<T>(FutureOr<T> Function() action) async {
    check();
    final result = await runZoned(
      () => Future<T>.sync(action),
      zoneValues: {_zoneKey: this},
    );
    check();
    return result;
  }

  Future<void> wait(Duration duration) async {
    check();
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      await run(() => done.future);
    } finally {
      timer.cancel();
    }
  }

  void dispose() {
    _timer?.cancel();
    _parent?._children.remove(this);
  }
}
