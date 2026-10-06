import 'dart:async';
import 'dart:typed_data';

import 'package:venera_next/foundation/operation_failure.dart';

import 'app_dio.dart';

/// An exclusively owned client. Cancelling Dio's delivery does not imply that
/// its adapter has finished; retain fetches and native cleanup until both end.
class OwnedDioClient {
  OwnedDioClient(this.dio) : _adapter = dio.httpClientAdapter {
    dio.httpClientAdapter = _OwnedAdapter(this);
  }

  final Dio dio;
  final HttpClientAdapter _adapter;
  final _pending = <Future<void>>{};
  final _lateFailures = <({Object error, StackTrace stack})>[];
  Future<void>? _closing;

  Future<ResponseBody> _fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) {
    if (_closing != null) {
      return Future.error(StateError('Owned HTTP client is closing'));
    }
    final done = Completer<ResponseBody>();
    late final Future<void> settled;
    settled = done.future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    Future.sync(() => _adapter.fetch(options, body, cancel))
        .then((response) async {
          if (_closing != null || options.cancelToken?.isCancelled == true) {
            // Dio's cancelled operation will never consume a late response.
            // Release its body here, including non-RHttp adapters.
            try {
              // Adapter ownership includes the unconsumed ResponseBody hook.
              // ignore: invalid_use_of_internal_member
              response.close();
            } catch (error, stack) {
              _lateFailures.add((error: error, stack: stack));
            }
            try {
              await response.stream
                  .listen((_) {}, onError: (Object _) {})
                  .cancel();
            } catch (error, stack) {
              _lateFailures.add((error: error, stack: stack));
            }
            throw options.cancelToken?.cancelError ??
                StateError('Owned HTTP client closed before response delivery');
          }
          return response;
        })
        .then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> closeAndWait({Object? cause, StackTrace? stackTrace}) {
    final closing = _closing;
    if (closing != null) return closing;
    final done = Completer<void>();
    _closing = done.future;
    _close(cause, stackTrace).then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> _close(Object? cause, StackTrace? stackTrace) async {
    final failures = <({Object error, StackTrace stack})>[];
    Future<void> release(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }

    await release(() => dio.close(force: true));
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    final adapter = _adapter;
    if (adapter is RHttpAdapter) await release(adapter.waitForIdle);
    failures.addAll(_lateFailures);
    if (failures.isNotEmpty) {
      throw DioCleanupFailure(failures, cause: cause, stackTrace: stackTrace);
    }
  }
}

class _OwnedAdapter implements HttpClientAdapter {
  _OwnedAdapter(this.owner);
  final OwnedDioClient owner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => owner._fetch(options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) => owner._adapter.close(force: force);
}

class DioCleanupFailure implements FailureDetails {
  DioCleanupFailure(
    Iterable<({Object error, StackTrace stack})> failures, {
    this.cause,
    this.stackTrace,
  }) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;
  @override
  final Object? cause;
  @override
  final StackTrace? stackTrace;
  @override
  FailureKind get kind => FailureKind.failed;
  @override
  String get message =>
      'HTTP cleanup failed: ${failures.map((failure) => failure.error).join('; ')}';
  @override
  String toString() => message;
}
