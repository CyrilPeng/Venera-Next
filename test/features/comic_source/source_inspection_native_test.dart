import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/features/comic_source/source_import.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });
  for (final preview in [false, true]) {
    test(
      'native inspection cancellation waits upload cleanup: preview=$preview',
      () async {
        final initialized = App.isInitialized;
        final version = App.version;
        final proxy = appdata.settings['proxy'];
        App.version = 'source-inspection-test';
        App.isInitialized = false;
        appdata.settings['proxy'] = 'direct';
        final released = Completer<void>();
        final cancelling = Completer<void>();
        final upload = StreamController<Uint8List>(
          onCancel: () {
            cancelling.complete();
            return released.future;
          },
        );
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        final received = Completer<void>();
        server.listen((socket) {
          sockets.add(socket);
          socket.listen((_) {
            if (!received.isCompleted) received.complete();
          }, onError: (Object _) {});
        });
        Dio createClient() => Dio()
          ..httpClientAdapter = RHttpAdapter()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                options.path = 'http://127.0.0.1:${server.port}/inspect';
                options.data = upload.stream;
                handler.next(options);
              },
            ),
          );
        final token = CancelToken();
        final Future<Object> request = preview
            ? SourceImportPreview.fromUrl(
                'https://example.test/source.js',
                createClient: createClient,
                cancelToken: token,
              )
            : SourceRepositories.instance.load(
                const SourceRepository(
                  id: 'native',
                  name: 'Native',
                  url: 'https://example.test/index.json',
                ),
                createClient: createClient,
                cancelToken: token,
              );
        var finished = false;
        final checked = expectLater(
          request.whenComplete(() => finished = true),
          throwsA(isA<DioException>()),
        );
        try {
          await received.future.timeout(const Duration(seconds: 10));
          token.cancel();
          await cancelling.future.timeout(const Duration(seconds: 10));
          await pumpEventQueue();
          expect(finished, isFalse);
          released.complete();
          await checked.timeout(const Duration(seconds: 10));
        } finally {
          token.cancel();
          if (!released.isCompleted) released.complete();
          await checked;
          unawaited(upload.close());
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
          App.isInitialized = initialized;
          App.version = version;
          appdata.settings['proxy'] = proxy;
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
