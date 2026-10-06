import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:venera_next/network/app_dio.dart';

/// Controls response and native cleanup separately, like RHttp cancellation.
class ApplicationUpdateAdapter extends RHttpAdapter {
  final entered = Completer<void>();
  final response = Completer<ResponseBody>();
  final draining = Completer<void>();
  final released = Completer<void>();
  final paths = <String>[];
  int closes = 0;
  Object? closeError;

  void complete(Object data, {int status = 200}) => response.complete(
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    ),
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    paths.add(options.path);
    if (!entered.isCompleted) entered.complete();
    return Future.any([
      response.future,
      if (cancelFuture != null)
        cancelFuture.then<ResponseBody>(
          (_) => throw options.cancelToken!.cancelError!,
        ),
    ]);
  }

  @override
  void close({bool force = false}) {
    closes++;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<void> waitForIdle() {
    if (!draining.isCompleted) draining.complete();
    return released.future;
  }
}
