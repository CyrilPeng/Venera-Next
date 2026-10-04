// Locked rhttp/FRB implementation details are isolated here because the public
// stream API discards its native completion Future (see _JoiningHandler).
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
// ignore: invalid_use_of_internal_member
import 'package:rhttp/src/model/exception.dart' show parseError;
// ignore: invalid_use_of_internal_member
import 'package:rhttp/src/model/settings.dart' show ClientSettingsExt;
import 'package:rhttp/src/rust/api/http.dart' as rust;
import 'package:rhttp/src/rust/api/stream.dart' as rust_stream;
import 'package:rhttp/src/rust/frb_generated.dart';
import 'package:rhttp/src/rust/lib.dart' show CancellationToken;

typedef RHttpCleanupError = ({String stage, Object error, StackTrace stack});

/// Transport cleanup failures, separate from HTTP errors and cancellation.
class RHttpCleanupFailure implements Exception {
  RHttpCleanupFailure(Iterable<RHttpCleanupError> failures)
    : failures = List.unmodifiable(failures);

  final List<RHttpCleanupError> failures;

  @override
  String toString() =>
      'RHttpCleanupFailure: ${failures.map((f) => '${f.stage}: ${f.error}').join('; ')}';
}

/// The response may settle before [finished]. Only [finished] acknowledges that
/// the native request has returned and its upload resources have been released.
@visibleForTesting
class RHttpStreamCall {
  RHttpStreamCall({
    required this.response,
    required this.body,
    required this.finished,
    required this.cancel,
  });

  final Future<({int statusCode, Map<String, List<String>> headers})> response;
  final Stream<Uint8List> body;
  final Future<void> finished;
  final Future<void> Function() cancel;
}

typedef RHttpStreamCallFactory =
    Future<RHttpStreamCall> Function(
      RequestOptions options,
      rhttp.ClientSettings settings,
      Stream<Uint8List>? upload,
    );

/// Owns a streaming request independently of Dio's early cancellation result.
class RHttpStreamRequest {
  RHttpStreamRequest({
    required this.options,
    required Future<rhttp.ClientSettings> settings,
    required Stream<Uint8List>? upload,
    required String Function(int) statusMessage,
    RHttpStreamCallFactory? start,
  }) {
    _body.onCancel = () {
      cancel();
      // Dio discards the response subscription's cancel Future. Still join
      // all cleanup, including a release already in progress, but keep errors
      // on the original done Future owned by the adapter's idle wait.
      return done.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    };
    done = _run(settings, upload, statusMessage, start ?? _startNativeCall);
  }

  final RequestOptions options;
  final _response = Completer<ResponseBody>();
  final _body = StreamController<Uint8List>();
  final _failures = <RHttpCleanupError>[];
  RHttpStreamCall? _call;
  Future<void>? _cancelling;
  bool _cancelled = false;
  bool _finished = false;
  late final Future<void> done;

  Future<ResponseBody> get response => _response.future;

  /// Stops delivery immediately, while [done] continues waiting for native exit.
  void cancel() {
    if (_finished) return;
    _cancelled = true;
    final call = _call;
    if (call != null && _cancelling == null) {
      _cancelling = _cleanup('cancel native request', call.cancel);
    }
  }

  Future<void> _cleanup(String stage, FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      if (error is RHttpCleanupFailure) {
        _failures.addAll(error.failures);
      } else {
        _failures.add((stage: stage, error: error, stack: stack));
      }
    }
  }

  DioException _cancelError() => DioException.requestCancelled(
    requestOptions: options,
    reason: 'HTTP request cancelled',
  );

  Future<void> _run(
    Future<rhttp.ClientSettings> settings,
    Stream<Uint8List>? upload,
    String Function(int) statusMessage,
    RHttpStreamCallFactory start,
  ) async {
    StreamSubscription<Uint8List>? subscription;
    Future<void>? nativeDone;
    var nativeSucceeded = false;
    try {
      final configured = await settings;
      if (_cancelled) throw _cancelError();
      final call = _call = await start(options, configured, upload);
      nativeDone = _cleanup('finish native request', () async {
        await call.finished;
        nativeSucceeded = true;
      });
      final bodyDone = Completer<void>();
      // Do not propagate downstream pause/cancel to the native observation.
      // rhttp already eagerly reads the native body; pausing cannot backpressure
      // Rust and must not prevent shutdown from observing completion.
      subscription = call.body.listen(
        (data) {
          if (!_cancelled) _body.add(data);
        },
        onError: (Object error, StackTrace stack) {
          if (!_cancelled) {
            _body.addError(error, stack);
          }
        },
        onDone: bodyDone.complete,
      );
      if (_cancelled) cancel();
      try {
        final headers = await call.response;
        if (_cancelled) throw _cancelError();
        _response.complete(
          ResponseBody(
            _body.stream,
            headers.statusCode,
            headers: headers.headers,
            statusMessage: statusMessage(headers.statusCode),
            onClose: cancel,
          ),
        );
      } catch (error, stack) {
        _response.completeError(error, stack);
        cancel();
      }
      await nativeDone;
      await _cancelling;
      // A failed bridge completion may leave the Dart stream without onDone.
      // Native ownership has ended, so finally can cancel that observation.
      // A successful completion must still drain queued body events normally.
      if (nativeSucceeded) await bodyDone.future;
    } catch (error, stack) {
      if (error is RHttpCleanupFailure) _failures.addAll(error.failures);
      if (!_response.isCompleted) _response.completeError(error, stack);
      cancel();
    } finally {
      await nativeDone;
      await _cancelling;
      _finished = true;
      _call = null;
      if (subscription != null) {
        await _cleanup('release response subscription', subscription.cancel);
      }
      // An unconsumed/paused response must not block native resource release.
      unawaited(_body.close());
    }
    if (_failures.isNotEmpty) throw RHttpCleanupFailure(_failures);
  }
}

/// rhttp 0.15.1 / FRB 2.11.1's generated stream method discards the Future from
/// executeNormal. Its Dart stream can finish on a decoding error before Rust
/// exits, so onDone is NOT a native completion acknowledgment. A per-call API
/// instance shares the runtime and wire but captures that actual native Future.
/// No global handler/runtime is replaced and no generated serialization is copied.
class _JoiningHandler extends BaseHandler {
  _JoiningHandler(this.delegate);

  final BaseHandler delegate;
  late Future<void> finished;

  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    final pending = delegate.executeNormal<S, E>(task);
    finished = pending.then<void>((_) {});
    // The generated method uses unawaited(). The retained Future above owns
    // errors; prevent that discarded branch from reporting an unhandled error.
    return pending.then<S>(
      (value) => value,
      onError: (Object _, StackTrace _) => null as S,
    );
  }
}

Future<RHttpStreamCall> _startNativeCall(
  RequestOptions options,
  rhttp.ClientSettings settings,
  Stream<Uint8List>? upload,
) async {
  // These accesses deliberately bind this shim to the locked rhttp/FRB codegen.
  // ignore: invalid_use_of_internal_member
  final original = RustLib.instance.api as RustLibApiImpl;
  // ignore: invalid_use_of_protected_member
  final joining = _JoiningHandler(original.handler);
  final api = RustLibApiImpl(
    handler: joining,
    // ignore: invalid_use_of_protected_member
    wire: original.wire,
    generalizedFrbRustBinding: original.generalizedFrbRustBinding,
    portManager: original.portManager,
  );
  final request = rhttp.HttpRequest(
    method: rhttp.HttpMethod(options.method),
    url: options.uri.toString(),
    settings: settings,
  );
  final response =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final tokenReady = Completer<CancellationToken>();
  final nativeExited = Completer<void>();
  final failures = <RHttpCleanupError>[];
  Future<void>? cancellation;
  var nativeFinished = false;
  Future<void> cancel() => cancellation ??= () async {
    if (nativeFinished) return;
    await Future.any<void>([
      tokenReady.future.then((_) {}),
      nativeExited.future,
    ]);
    if (!nativeFinished) {
      await rust.cancelRequest(token: await tokenReady.future);
    }
  }();
  Future<void> cleanup(String stage, FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      failures.add((stage: stage, error: error, stack: stack));
    }
  }

  rust_stream.Dart2RustStreamSink? sender;
  rust_stream.Dart2RustStreamReceiver? receiver;
  StreamIterator<Uint8List>? input;
  Future<void>? pumping;
  if (upload != null) {
    (sender, receiver) = await rust_stream.createStream();
  }
  late Stream<Uint8List> body;
  try {
    if (upload != null) input = StreamIterator(upload);
    body = api.crateApiHttpMakeHttpRequestReceiveStream(
      // The conversion preserves proxy, DNS, TLS, redirect and timeout settings.
      // ignore: invalid_use_of_internal_member
      settings: settings.toRustType(),
      method: rust.HttpMethod(method: options.method),
      url: '${settings.baseUrl ?? ''}${options.uri}',
      headers: rust.HttpHeaders.map({
        for (final entry in options.headers.entries)
          entry.key: entry.value.toString().trim(),
      }),
      body: upload == null ? null : const rust.HttpBody.bytesStream(),
      bodyStream: receiver,
      cancelable: true,
      onCancelToken: tokenReady.complete,
      onResponse: (value) {
        final headers = <String, List<String>>{};
        for (final (name, value) in value.headers) {
          (headers[name.toLowerCase()] ??= []).add(value);
        }
        if (!response.isCompleted) {
          response.complete((statusCode: value.statusCode, headers: headers));
        }
      },
      onError: (error) {
        if (!response.isCompleted) {
          // ignore: invalid_use_of_internal_member
          response.completeError(parseError(request, error));
        }
      },
    );
    if (upload != null) {
      final activeSender = sender!;
      final activeInput = input!;
      pumping = () async {
        try {
          final buffer = BytesBuilder(copy: false);
          while (await activeInput.moveNext()) {
            buffer.add(activeInput.current);
            if (buffer.length >= 1024 * 1024) {
              await activeSender.add(data: buffer.takeBytes());
            }
          }
          if (!nativeFinished) {
            if (buffer.isNotEmpty) {
              await activeSender.add(data: buffer.takeBytes());
            }
            await activeSender.close();
          }
        } catch (error, stack) {
          // Upload/network failures are request failures, not cleanup failures.
          if (!response.isCompleted) response.completeError(error, stack);
          await cleanup('cancel failed upload', cancel);
        }
      }();
    }
  } catch (error, stack) {
    if (input != null) {
      await cleanup('release failed upload subscription', input.cancel);
    }
    if (sender != null && !sender.isDisposed) {
      await cleanup('release failed upload sender', sender.dispose);
    }
    if (receiver != null && !receiver.isDisposed) {
      await cleanup('release failed upload receiver', receiver.dispose);
    }
    if (failures.isNotEmpty) {
      throw RHttpCleanupFailure([
        (stage: 'start native request', error: error, stack: stack),
        ...failures,
      ]);
    }
    Error.throwWithStackTrace(error, stack);
  }
  final finished = () async {
    await cleanup('await native completion', () => joining.finished);
    nativeFinished = true;
    nativeExited.complete();
    if (!response.isCompleted) {
      response.completeError(
        StateError('Native request ended without a response'),
      );
    }
    if (input != null) {
      await cleanup('cancel upload subscription', input.cancel);
    }
    await pumping;
    await cleanup('finish native cancellation', () async => await cancellation);
    if (sender != null && !sender.isDisposed) {
      await cleanup('release upload sender', sender.dispose);
    }
    if (receiver != null && !receiver.isDisposed) {
      await cleanup('release upload receiver', receiver.dispose);
    }
    if (tokenReady.isCompleted) {
      final token = await tokenReady.future;
      if (!token.isDisposed) {
        await cleanup('release cancellation token', token.dispose);
      }
    }
    if (failures.isNotEmpty) throw RHttpCleanupFailure(failures);
  }();
  return RHttpStreamCall(
    response: response.future,
    body: body.transform(
      StreamTransformer.fromHandlers(
        handleError:
            (Object error, StackTrace stack, EventSink<Uint8List> sink) {
              final mapped =
                  error is AnyhowException &&
                      error.message.contains('STREAM_CANCEL_ERROR')
                  ? rhttp.RhttpCancelException(request)
                  : rhttp.RhttpUnknownException(request, error.toString());
              sink.addError(mapped, stack);
            },
      ),
    ),
    finished: finished,
    cancel: cancel,
  );
}
