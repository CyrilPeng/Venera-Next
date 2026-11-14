import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/network/rhttp_stream_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production stream cancels an active native body before server EOF',
    () async {
      await rhttp.Rhttp.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final releaseServer = Completer<void>();
      final serverEntered = Completer<void>();
      final serverFinished = Completer<void>();
      server.listen((request) async {
        serverEntered.complete();
        try {
          // An unknown content length keeps the native request active after this
          // first byte. The server can send EOF only after the explicit barrier.
          request.response.bufferOutput = false;
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add([120]);
          await request.response.flush();
          await releaseServer.future;
        } on HttpException {
          // Cancellation can close the peer while the server is flushing.
        } on SocketException {
          // The cancelled peer has no obligation to keep its socket open.
        } finally {
          try {
            await request.response.close();
          } on HttpException {
            // The test owns server EOF, including an already closed connection.
          } on SocketException {
            // A cancelled native request may already have closed its socket.
          }
          serverFinished.complete();
        }
      });
      final request = RHttpStreamRequest(
        options: RequestOptions(
          path: 'http://127.0.0.1:${server.port}',
          method: 'GET',
          responseType: ResponseType.stream,
        ),
        settings: Future.value(
          const rhttp.ClientSettings(
            proxySettings: rhttp.ProxySettings.noProxy(),
            throwOnStatusCode: false,
          ),
        ),
        upload: null,
        statusMessage: (code) => '$code',
      );
      var returned = false;
      final completed = request.done.then<void>((_) => returned = true);
      StreamSubscription<List<int>>? subscription;
      addTearDown(() async {
        request.cancel();
        if (!releaseServer.isCompleted) releaseServer.complete();
        try {
          await request.done.timeout(const Duration(seconds: 10));
        } finally {
          await subscription?.cancel();
          await server.close(force: true);
          if (serverEntered.isCompleted) {
            await serverFinished.future.timeout(const Duration(seconds: 10));
          }
        }
      });
      Future<T> phase<T>(Future<T> future, String name) => future.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException(name, const Duration(seconds: 10)),
      );
      final response = await phase(request.response, 'receive native headers');
      expect(response.statusCode, 200);
      final firstByte = Completer<void>();
      final bodyFinished = Completer<void>();
      final bytes = <int>[];
      final errors = <Object>[];
      subscription = response.stream.listen(
        (chunk) {
          bytes.addAll(chunk);
          if (!firstByte.isCompleted) firstByte.complete();
        },
        onError: errors.add,
        onDone: bodyFinished.complete,
      );
      await phase(firstByte.future, 'receive first native body byte');
      expect(bytes, [120]);
      expect(returned, isFalse);
      expect(releaseServer.isCompleted, isFalse);
      request.cancel();
      await phase(completed, 'join cancelled native request');
      await phase(bodyFinished.future, 'finish cancelled production body');
      expect(returned, isTrue);
      expect(
        errors,
        everyElement(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(releaseServer.isCompleted, isFalse);
    },
  );
}
