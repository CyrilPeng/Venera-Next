import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';

void main() {
  setUp(() {
    appdata.settings['proxy'] = 'direct';
    appdata.settings['ignoreBadCertificate'] = false;
    appdata.settings['enableDnsOverrides'] = false;
    appdata.settings['dnsOverrides'] = {};
    appdata.settings['sni'] = true;
    invalidateProxyCache();
  });

  tearDown(() {
    appdata.settings['proxy'] = 'system';
    appdata.settings['ignoreBadCertificate'] = false;
    appdata.settings['enableDnsOverrides'] = false;
    appdata.settings['dnsOverrides'] = {};
    appdata.settings['sni'] = true;
    invalidateProxyCache();
  });

  test('prevent-parallel queues requests with the same path', () async {
    final dio = AppDio();
    final adapter = _TrackingAdapter();
    dio.httpClientAdapter = adapter;

    Future<Response<String>> request() {
      return dio.get<String>(
        'https://example.com/resource',
        options: Options(headers: {'prevent-parallel': 'true'}),
      );
    }

    final first = request();
    await adapter.firstStarted.future;

    final second = request();
    await pumpEventQueue();

    expect(adapter.started, 1);

    adapter.releaseFirst.complete();
    await Future.wait([first, second]);

    expect(adapter.started, 2);
    expect(adapter.maxActive, 1);
  });

  test(
    'disabled DNS overrides do not affect custom socket connections',
    () async {
      final server = await _serveText('direct');
      addTearDown(() => server.close(force: true));
      appdata.settings['enableDnsOverrides'] = false;
      appdata.settings['dnsOverrides'] = {'127.0.0.1': '127.0.0.2'};
      appdata.settings['sni'] = false;

      final dio = AppDio();
      addTearDown(() => dio.close(force: true));

      final response = await dio.get<String>(
        'http://127.0.0.1:${server.port}/',
      );

      expect(response.data, 'direct');
    },
  );

  test('enabled DNS overrides connect to the configured address', () async {
    final server = await _serveText('override');
    addTearDown(() => server.close(force: true));
    appdata.settings['enableDnsOverrides'] = true;
    appdata.settings['dnsOverrides'] = {'venera.invalid': '127.0.0.1'};

    final dio = AppDio();
    addTearDown(() => dio.close(force: true));

    final response = await dio.get<String>(
      'http://venera.invalid:${server.port}/',
    );

    expect(response.data, 'override');
  });
}

Future<HttpServer> _serveText(String text) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      request.response.write(text);
      await request.response.close();
    }
  }());
  return server;
}

class _TrackingAdapter implements HttpClientAdapter {
  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();

  int active = 0;
  int maxActive = 0;
  int started = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    active++;
    if (active > maxActive) {
      maxActive = active;
    }
    started++;
    final requestIndex = started;
    try {
      if (requestIndex == 1) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      return ResponseBody.fromString(
        'ok',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    } finally {
      active--;
    }
  }

  @override
  void close({bool force = false}) {}
}
