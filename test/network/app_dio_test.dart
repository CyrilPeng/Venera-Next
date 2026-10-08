import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/json_response.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  group('JSON response validation', () {
    Response<dynamic> response({
      required Object? data,
      Map<String, dynamic> requestHeaders = const {},
      Map<String, List<String>> responseHeaders = const {},
      String path = 'https://example.com/api',
      int statusCode = 200,
    }) {
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path, headers: requestHeaders),
        data: data,
        headers: Headers.fromMap(responseHeaders),
        statusCode: statusCode,
      );
    }

    test('rejects malformed JSON when the response declares JSON', () {
      final result = isMalformedExpectedJsonResponse(
        response(
          data: '<html>temporary gateway response</html>',
          responseHeaders: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        ),
      );

      expect(result, isTrue);
    });

    test('rejects malformed JSON when the request accepts JSON', () {
      final result = isMalformedExpectedJsonResponse(
        response(
          data: '{"items":',
          requestHeaders: {'Accept': 'application/json'},
          responseHeaders: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      );

      expect(result, isTrue);
    });

    test('accepts valid JSON and ordinary HTML responses', () {
      expect(
        isMalformedExpectedJsonResponse(
          response(
            data: '{"items":[]}',
            responseHeaders: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        ),
        isFalse,
      );
      expect(
        isMalformedExpectedJsonResponse(
          response(
            data: '<html>comic page</html>',
            responseHeaders: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          ),
        ),
        isFalse,
      );
    });

    test('allows empty no-content responses', () {
      expect(
        isMalformedExpectedJsonResponse(
          response(
            data: '',
            requestHeaders: {'Accept': 'application/json'},
            statusCode: 204,
          ),
        ),
        isFalse,
      );
    });
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
    'uses the current cookie jar after the single instance is replaced',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('venera-app-dio-');
      final previousIsInitialized = App.isInitialized;
      final previousDataPath = previousIsInitialized ? App.dataPath : null;
      final previousCachePath = previousIsInitialized ? App.cachePath : null;
      final previousCookieJar = SingleInstanceCookieJar.instance;
      final previousLogMuted = Log.isMuted;
      SingleInstanceCookieJar? oldCookieJar;
      SingleInstanceCookieJar? newCookieJar;

      addTearDown(() {
        try {
          newCookieJar?.dispose();
        } catch (_) {
          // ignore cleanup failures for already-disposed test databases
        }
        SingleInstanceCookieJar.instance = previousCookieJar;
        if (previousDataPath != null) {
          App.dataPath = previousDataPath;
        }
        if (previousCachePath != null) {
          App.cachePath = previousCachePath;
        }
        App.isInitialized = previousIsInitialized;
        Log.isMuted = previousLogMuted;
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      App.isInitialized = true;
      App.dataPath = tempDir.path;
      App.cachePath = tempDir.path;
      Log.isMuted = true;
      SingleInstanceCookieJar.instance = null;
      oldCookieJar = SingleInstanceCookieJar(p.join(tempDir.path, 'old.db'));

      final dio = AppDio();
      final adapter = _TrackingAdapter();
      dio.httpClientAdapter = adapter;

      oldCookieJar.dispose();
      SingleInstanceCookieJar.instance = null;
      newCookieJar = SingleInstanceCookieJar(p.join(tempDir.path, 'new.db'));
      newCookieJar.saveFromResponse(Uri.parse('https://example.com/resource'), [
        Cookie('fresh', '1'),
      ]);

      final request = dio.get<String>('https://example.com/resource');
      await adapter.firstStarted.future;
      adapter.releaseFirst.complete();
      await request;

      expect(adapter.requestHeaders, hasLength(1));
      expect(adapter.requestHeaders.single['cookie'], 'fresh=1');
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _TrackingAdapter implements HttpClientAdapter {
  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();

  int active = 0;
  int maxActive = 0;
  int started = 0;
  final requestHeaders = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    active++;
    requestHeaders.add(Map<String, dynamic>.from(options.headers));
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
