// Exercises the locked native bridge directly, including its callback ack.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
// ignore: invalid_use_of_internal_member
import 'package:rhttp/src/model/settings.dart' show ClientSettingsExt;
import 'package:rhttp/src/rust/api/error.dart';
import 'package:rhttp/src/rust/api/http.dart' as rust;
import 'package:rhttp/src/rust/frb_generated.dart';
import 'package:rhttp/src/rust/lib.dart' show CancellationToken;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native cancellation retains response callback until Dart acknowledges',
    () async {
      await rhttp.Rhttp.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = 1;
        request.response.write('x');
        await request.response.close();
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      final token = Completer<CancellationToken>();
      final cancellationReported = Completer<void>();
      // ignore: invalid_use_of_internal_member
      final original = RustLib.instance.api as RustLibApiImpl;
      // ignore: invalid_use_of_protected_member
      final handler = _ObserveNativeReturn(original.handler);
      final api = RustLibApiImpl(
        handler: handler,
        // ignore: invalid_use_of_protected_member
        wire: original.wire,
        generalizedFrbRustBinding: original.generalizedFrbRustBinding,
        portManager: original.portManager,
      );
      final body = api.crateApiHttpMakeHttpRequestReceiveStream(
        settings: const rhttp.ClientSettings(
          proxySettings: rhttp.ProxySettings.noProxy(),
          throwOnStatusCode: false,
          // ignore: invalid_use_of_internal_member
        ).toRustType(),
        method: const rust.HttpMethod(method: 'GET'),
        url: 'http://127.0.0.1:${server.port}',
        cancelable: true,
        onCancelToken: token.complete,
        onResponse: (_) async {
          entered.complete();
          await release.future;
        },
        onError: (error) {
          expect(error, isA<RhttpError_RhttpCancelError>());
          cancellationReported.complete();
        },
      );
      final bodyDone = Completer<void>();
      final subscription = body.listen(
        (_) {},
        onError: (Object _) {},
        onDone: bodyDone.complete,
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await handler.finished;
        await subscription.cancel();
        final nativeToken = await token.future;
        if (!nativeToken.isDisposed) nativeToken.dispose();
        await server.close(force: true);
      });
      await entered.future.timeout(const Duration(seconds: 10));
      await rust.cancelRequest(token: await token.future);
      await cancellationReported.future.timeout(const Duration(seconds: 10));
      // FRB's Dart stream ends on its error before the held response ack arrives.
      // Native completion must continue waiting; upstream 0.15.1 drops the ack
      // receiver here and aborts when release completes.
      await bodyDone.future.timeout(const Duration(seconds: 10));
      var returned = false;
      final finished = handler.finished.then((_) => returned = true);
      await pumpEventQueue();
      expect(returned, isFalse);
      release.complete();
      await finished.timeout(const Duration(seconds: 10));
      expect(returned, isTrue);
    },
    skip: !Platform.isWindows,
  );
}

class _ObserveNativeReturn extends BaseHandler {
  _ObserveNativeReturn(this.delegate);
  final BaseHandler delegate;
  late Future<void> finished;

  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    final result = delegate.executeNormal<S, E>(task);
    finished = result.then<void>((_) {});
    return result;
  }
}
