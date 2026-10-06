import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/owned_dio_client.dart';

void main() {
  for (final failCleanup in [false, true]) {
    test(
      'retired fetch waits late response body cancellation: fails=$failCleanup',
      () async {
        final adapter = _Adapter();
        final client = OwnedDioClient(Dio()..httpClientAdapter = adapter);
        final token = CancelToken();
        final request = expectLater(
          client.dio.get<String>(
            'https://example.test/late',
            cancelToken: token,
          ),
          throwsA(isA<DioException>()),
        );
        await adapter.entered.future;
        token.cancel();
        await request;
        var closed = false;
        final close = client.closeAndWait();
        final outcome = failCleanup
            ? expectLater(
                close,
                throwsA(
                  isA<DioCleanupFailure>().having(
                    (e) => e.failures.map((f) => f.error.toString()).toList(),
                    'body release failures',
                    ['Bad state: body close', 'Bad state: body cancel'],
                  ),
                ),
              )
            : close.then((_) => closed = true);
        final cancelStarted = Completer<void>();
        final release = Completer<void>();
        final body = StreamController<Uint8List>(
          onCancel: () {
            cancelStarted.complete();
            return release.future;
          },
        );
        var bodyClosed = false;
        adapter.response.complete(
          ResponseBody(
            body.stream,
            200,
            onClose: () {
              bodyClosed = true;
              if (failCleanup) throw StateError('body close');
            },
          ),
        );
        await cancelStarted.future;
        expect(bodyClosed, isTrue);
        expect(closed, isFalse);
        if (failCleanup) {
          release.completeError(StateError('body cancel'));
        } else {
          release.complete();
        }
        await outcome;
        expect(client.closeAndWait(), same(close));
        expect(adapter.closes, 1);
        await body.close();
      },
    );
  }
}

class _Adapter implements HttpClientAdapter {
  final entered = Completer<void>();
  final response = Completer<ResponseBody>();
  int closes = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    entered.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {
    expect(force, isTrue);
    closes++;
  }
}
