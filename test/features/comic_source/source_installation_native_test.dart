import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native installation shutdown joins delayed upload subscription cleanup',
    () async {
      await rhttp.Rhttp.init();
      App.version = 'app-update-native-test';
      final previousInitialized = App.isInitialized;
      final previousProxy = appdata.settings['proxy'];
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
      final service = SourceInstallations(
        manager: ComicSourceManager(),
        repositories: SourceRepositories.instance,
        createClient: () {
          final dio = Dio()..httpClientAdapter = RHttpAdapter();
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                options.path = 'http://127.0.0.1:${server.port}/latest';
                options.data = upload.stream;
                handler.next(options);
              },
            ),
          );
          return dio;
        },
      );
      addTearDown(() async {
        if (!released.isCompleted) released.complete();
        await service.closeAndWait();
        unawaited(upload.close());
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        App.isInitialized = previousInitialized;
        appdata.settings['proxy'] = previousProxy;
      });
      final task = service.enqueueUrl('https://example.test/source.js');
      await received.future.timeout(const Duration(seconds: 10));
      var closed = false;
      final closing = service.closeAndWait().then((_) => closed = true);
      await cancelling.future.timeout(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(closed, isFalse);
      released.complete();
      await Future.wait([closing]).timeout(const Duration(seconds: 10));
      expect(task.phase, SourceInstallPhase.canceled);
    },
    skip: !Platform.isWindows,
  );
}
