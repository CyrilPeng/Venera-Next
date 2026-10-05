import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  late Directory directory;
  late AppDataOperations operations;
  late CookieJarSql jar;
  final uri = Uri.parse('https://example.test/');
  setUp(() {
    directory = Directory.systemTemp.createTempSync('cookie-admission-');
    operations = AppDataOperations();
    jar = CookieJarSql('${directory.path}/cookie.db', operations: operations);
  });
  tearDown(() {
    jar.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'replacement rejects synchronous SQL including expiration cleanup',
    () async {
      jar.saveFromResponse(uri, [
        Cookie('expired', 'old')..expires = DateTime.utc(2000),
      ]);
      final release = Completer<void>();
      final replacement = operations.run(() => release.future);
      for (final action in <void Function()>[
        () => jar.loadForRequest(uri),
        () => jar.loadForRequestCookieHeader(uri),
        () => jar.saveFromResponse(uri, [Cookie('new', 'value')]),
        () => jar.saveFromResponseCookieHeader(uri, ['new=value']),
        () => jar.delete(uri, 'expired'),
        () => jar.deleteUri(uri),
        jar.dispose,
      ]) {
        expect(action, throwsA(isA<AppDataBusyException>()));
      }
      final raw = sqlite3.open(jar.path);
      expect(raw.select('SELECT name FROM cookies').single['name'], 'expired');
      raw.dispose();
      release.complete();
      await replacement;
      expect(jar.loadForRequest(uri), isEmpty);
    },
  );

  test('schema initialization cannot touch files during replacement', () async {
    final release = Completer<void>();
    final replacement = operations.run(() => release.future);
    final path = '${directory.path}/new.db';
    expect(
      () => CookieJarSql(path, operations: operations),
      throwsA(isA<AppDataBusyException>()),
    );
    expect(File(path).existsSync(), isFalse);
    release.complete();
    await replacement;
  });

  test('queued save snapshots mutable cookies and lists', () async {
    final release = Completer<void>();
    final replacement = operations.run(() => release.future);
    final cookie = Cookie('session', 'captured')..path = '/';
    final input = [cookie];
    final save = jar.saveFromResponseAsync(uri, input);
    cookie.value = 'later';
    cookie.domain = 'other.test';
    input.clear();
    release.complete();
    await replacement;
    await save;
    expect(jar.loadForRequestCookieHeader(uri), 'session=captured');
  });

  test('queued login save cannot cross a same-path reopen', () async {
    final release = Completer<void>();
    final old = jar;
    final replacement = operations.run(() async {
      old.dispose();
      await release.future;
      jar = CookieJarSql(old.path, operations: operations);
      jar.saveFromResponse(uri, [Cookie('session', 'imported')]);
    });
    final save = old.saveFromResponseAsync(uri, [Cookie('session', 'stale')]);
    final observed = expectLater(save, throwsStateError);
    release.complete();
    await replacement;
    await observed;
    expect(jar.loadForRequestCookieHeader(uri), 'session=imported');
  });

  test(
    'new HTTP request waits for reopen and uses the imported cookies',
    () async {
      final adapter = _ResponseGate();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        CookieManagerSql.dynamic(() => jar, operations: operations),
      );
      addTearDown(() => dio.close(force: true));
      final release = Completer<void>();
      final replacement = operations.run(() async {
        jar.dispose();
        await release.future;
        jar = CookieJarSql(jar.path, operations: operations);
        jar.saveFromResponse(uri, [Cookie('session', 'imported')]);
      });
      final request = dio.get<String>(uri.toString());
      await pumpEventQueue();
      expect(adapter.requests, isEmpty);
      release.complete();
      await replacement;
      final options = await adapter.started.future;
      expect(options.headers['cookie'], 'session=imported');
      adapter.response.complete(ResponseBody.fromString('ok', 200));
      expect((await request).data, 'ok');
    },
  );

  for (final responseDuringReplacement in [false, true]) {
    test(
      'old response preserves same-path imported session (during=$responseDuringReplacement)',
      () async {
        jar.saveFromResponse(uri, [Cookie('session', 'old')]);
        final adapter = _ResponseGate();
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(
          CookieManagerSql.dynamic(() => jar, operations: operations),
        );
        addTearDown(() => dio.close(force: true));
        final request = dio.get<String>(uri.toString());
        await adapter.started.future;
        final release = Completer<void>();
        final replacement = operations.run(() async {
          jar.dispose();
          await release.future;
          jar = CookieJarSql(jar.path, operations: operations);
          jar.saveFromResponse(uri, [Cookie('session', 'imported')]);
        });
        if (!responseDuringReplacement) {
          release.complete();
          await replacement;
        }
        adapter.response.complete(
          ResponseBody.fromString(
            'old response',
            200,
            headers: {
              'set-cookie': ['session=stale; Path=/'],
            },
          ),
        );
        if (responseDuringReplacement) {
          var completed = false;
          final observed = request.then((_) => completed = true);
          await pumpEventQueue();
          expect(completed, isFalse);
          release.complete();
          await replacement;
          await observed;
        }
        expect((await request).data, 'old response');
        expect(jar.loadForRequestCookieHeader(uri), 'session=imported');
      },
    );
  }

  test(
    'response queued behind export is saved to its unchanged owner',
    () async {
      final adapter = _ResponseGate();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(CookieManagerSql(jar));
      addTearDown(() => dio.close(force: true));
      final request = dio.get<String>(uri.toString());
      await adapter.started.future;
      final release = Completer<void>();
      final export = operations.run(() => release.future);
      adapter.response.complete(
        ResponseBody.fromString(
          'ok',
          200,
          headers: {
            'set-cookie': ['session=saved; Path=/'],
          },
        ),
      );
      await pumpEventQueue();
      release.complete();
      await export;
      await request;
      expect(jar.loadForRequestCookieHeader(uri), 'session=saved');
    },
  );

  test(
    'request canceled while waiting never touches SQL or transport',
    () async {
      final adapter = _ResponseGate();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(CookieManagerSql(jar));
      addTearDown(() => dio.close(force: true));
      final release = Completer<void>();
      final replacement = operations.run(() => release.future);
      final token = CancelToken();
      final request = dio.get<String>(uri.toString(), cancelToken: token);
      final observed = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await pumpEventQueue();
      token.cancel('leaving');
      await observed;
      release.complete();
      await replacement;
      await pumpEventQueue();
      expect(adapter.requests, isEmpty);
    },
  );

  for (final loadFailure in [false, true]) {
    test(
      'SQL ${loadFailure ? 'load' : 'save'} failure retains cause and stack',
      () async {
        if (loadFailure) {
          jar.saveFromResponse(uri, [
            Cookie('expired', 'old')..expires = DateTime.utc(2000),
          ]);
        }
        final raw = sqlite3.open(jar.path);
        raw.execute(
          'CREATE TRIGGER fail_cookie BEFORE ${loadFailure ? 'DELETE' : 'INSERT'} '
          "ON cookies BEGIN SELECT RAISE(ABORT, 'cookie disk failure'); END",
        );
        raw.dispose();
        final adapter = _ResponseGate();
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(CookieManagerSql(jar));
        addTearDown(() => dio.close(force: true));
        final request = dio.get<String>(uri.toString());
        final observed = expectLater(
          request,
          throwsA(
            isA<DioException>()
                .having(
                  (e) => e.error,
                  'original error',
                  isA<SqliteException>(),
                )
                .having(
                  (e) => e.stackTrace.toString(),
                  'original stack',
                  contains('cookie_jar.dart'),
                ),
          ),
        );
        if (!loadFailure) {
          await adapter.started.future;
          adapter.response.complete(
            ResponseBody.fromString(
              'ok',
              200,
              headers: {
                'set-cookie': ['session=new; Path=/'],
              },
            ),
          );
        }
        await observed;
        if (loadFailure) expect(adapter.requests, isEmpty);
      },
    );
  }
}

class _ResponseGate implements HttpClientAdapter {
  final started = Completer<RequestOptions>();
  final response = Completer<ResponseBody>();
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    if (!started.isCompleted) started.complete(options);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}
