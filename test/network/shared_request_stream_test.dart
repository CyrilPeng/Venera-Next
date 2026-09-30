import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/shared_request_stream.dart';

void main() {
  test(
    'starts only on listen and unlistened handles do not retain work',
    () async {
      var starts = 0;
      var closed = 0;
      late RequestScope scope;
      final source = StreamController<int>();
      final shared = SharedRequestStream<int>((request) {
        starts++;
        scope = request;
        return source.stream;
      }, (_) => closed++);
      final unused = shared.stream;
      expect(starts, 0);
      final subscription = shared.stream.listen((_) {});
      expect(starts, 1);
      await subscription.cancel();
      expect(scope.cancelToken.isCancelled, true);
      expect(closed, 1);
      expect(await unused.toList(), isEmpty);
      shared.cancel();
      expect(closed, 1);
      await source.close();
    },
  );

  test(
    'shared request is independent of the initiating caller scope',
    () async {
      final caller = RequestScope();
      late RequestScope request;
      final source = StreamController<int>();
      final shared = await caller.run(
        () => SharedRequestStream<int>((scope) {
          request = scope;
          return source.stream;
        }, (_) {}),
      );
      final first = shared.stream.listen((_) {});
      final events = <int>[];
      final second = shared.stream.listen(events.add);
      caller.cancel();
      await first.cancel();
      expect(request.isCancelled, false);
      source.add(42);
      await pumpEventQueue();
      expect(events, [42]);
      await second.cancel();
      expect(request.isCancelled, true);
      caller.dispose();
      await source.close();
    },
  );

  test(
    'natural completion and synchronous factory failure close once',
    () async {
      var closes = 0;
      final completed = SharedRequestStream<int>(
        (_) => Stream.value(1),
        (_) => closes++,
      );
      expect(await completed.stream.toList(), [1]);
      completed.cancel();
      expect(closes, 1);
      final failed = SharedRequestStream<int>(
        (_) => throw StateError('failed'),
        (_) => closes++,
      );
      await expectLater(failed.stream.toList(), throwsStateError);
      failed.cancel();
      expect(closes, 2);
    },
  );

  test('last subscriber aborts a real stalled HTTP request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    server.listen((request) {
      if (!received.isCompleted) received.complete();
    });
    final dio = AppDio()..httpClientAdapter = IOHttpClientAdapter();
    final aborted = Completer<Object>();
    final shared = SharedRequestStream<int>((scope) async* {
      try {
        await dio.get<String>(
          'http://127.0.0.1:${server.port}/stalled',
          cancelToken: scope.cancelToken,
        );
        yield 1;
      } catch (error) {
        aborted.complete(error);
        rethrow;
      }
    }, (_) {});
    addTearDown(() async {
      shared.cancel();
      dio.close(force: true);
      await server.close(force: true);
    });
    final first = shared.stream.listen((_) {});
    final second = shared.stream.listen((_) {});
    await received.future.timeout(const Duration(seconds: 5));
    await first.cancel();
    expect(aborted.isCompleted, false);
    await second.cancel();
    final error = await aborted.future.timeout(const Duration(seconds: 5));
    expect(
      error,
      isA<DioException>().having(
        (e) => e.type,
        'type',
        DioExceptionType.cancel,
      ),
    );
  });
}
