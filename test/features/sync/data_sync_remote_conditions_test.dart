import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/features/sync/data_sync_remote_port.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  late Directory directory;
  late File source;
  final bytes = Uint8List.fromList(List.generate(1027, (i) => i % 251));
  final hash = sha256.convert(bytes).toString();

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sync-remote-conditions-');
    source = File('${directory.path}/upload.venera')..writeAsBytesSync(bytes);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<DataSyncArchiveCreateResult> create(_Fixture fixture) =>
      fixture.remote.createArchiveIfAbsent(
        'Snapshot.venera',
        source,
        sha256: hash,
        length: bytes.length,
      );

  test(
    'create, GET proof and retention DELETE use independent conditional headers',
    () async {
      Uint8List? stored;
      final fixture = _Fixture((request) {
        switch (request.options.method) {
          case 'PUT':
            expect(request.options.headers[HttpHeaders.ifNoneMatchHeader], '*');
            expect(request.options.headers[HttpHeaders.ifMatchHeader], isNull);
            if (stored != null) return _response(412);
            stored = request.body;
            return _response(201);
          case 'GET':
            expect(
              request.options.headers[HttpHeaders.ifNoneMatchHeader],
              isNull,
            );
            expect(request.options.headers[HttpHeaders.ifMatchHeader], isNull);
            return stored == null
                ? _response(404)
                : _response(
                    200,
                    bytes: stored!,
                    headers: {
                      'etag': ['"stable-tag"'],
                    },
                  );
          case 'DELETE':
            expect(
              request.options.headers[HttpHeaders.ifMatchHeader],
              '"stable-tag"',
            );
            expect(
              request.options.headers[HttpHeaders.ifNoneMatchHeader],
              isNull,
            );
            stored = null;
            return _response(204);
          default:
            throw StateError('Unexpected ${request.options.method}');
        }
      });
      addTearDown(fixture.remote.dispose);
      final originalHeaders = Map<String, dynamic>.of(
        fixture.client.c.options.headers,
      );
      expect(await create(fixture), DataSyncArchiveCreateResult.created);
      expect(
        await create(fixture),
        DataSyncArchiveCreateResult.preconditionFailed,
      );
      expect(stored, bytes);
      final present =
          await fixture.remote.probeArchive('Snapshot.venera')
              as DataSyncArchivePresent;
      expect(present.sha256, hash);
      expect(present.length, bytes.length);
      expect(present.strongEtag, '"stable-tag"');
      expect(
        await fixture.remote.removeArchiveIfUnchanged(
          'Snapshot.venera',
          strongEtag: present.strongEtag!,
        ),
        DataSyncArchiveRemoveResult.removed,
      );
      expect(
        await fixture.remote.probeArchive('Snapshot.venera'),
        isA<DataSyncArchiveMissing>(),
      );
      expect(fixture.client.c.options.headers, originalHeaders);
      expect(fixture.requests.map((r) => r.options.method), [
        'PUT',
        'PUT',
        'GET',
        'DELETE',
        'GET',
      ]);
      for (final request in fixture.requests) {
        expect(request.options.uri.path, '/dav/MixedRoot/Snapshot.venera');
        expect(request.options.followRedirects, isFalse);
        expect(request.options.maxRedirects, 0);
        expect(
          request.options.headers[HttpHeaders.acceptEncodingHeader],
          'identity',
        );
      }
    },
  );

  test('changed or truncated local snapshot is rejected before PUT', () async {
    final fixture = _Fixture((_) => throw StateError('Must not send'));
    addTearDown(fixture.remote.dispose);
    source.writeAsBytesSync(List.filled(bytes.length, 99));
    await expectLater(create(fixture), throwsStateError);
    source.writeAsBytesSync(bytes.sublist(1));
    await expectLater(create(fixture), throwsStateError);
    expect(fixture.requests, isEmpty);
  });

  test(
    'concurrent replacement makes retention DELETE fail its precondition',
    () async {
      var etag = '"before"';
      final replacement = Uint8List.fromList([8, 9]);
      var stored = bytes;
      final fixture = _Fixture((request) {
        if (request.options.method == 'GET') {
          return _response(
            200,
            bytes: stored,
            headers: {
              'etag': [etag],
            },
          );
        }
        expect(request.options.method, 'DELETE');
        if (request.options.headers[HttpHeaders.ifMatchHeader] != etag) {
          return _response(412);
        }
        stored = Uint8List(0);
        return _response(204);
      });
      addTearDown(fixture.remote.dispose);
      final evidence =
          await fixture.remote.probeArchive('other-device.venera')
              as DataSyncArchivePresent;
      expect(evidence.sha256, hash);
      etag = '"replacement"';
      stored = replacement;
      expect(
        await fixture.remote.removeArchiveIfUnchanged(
          'other-device.venera',
          strongEtag: evidence.strongEtag!,
        ),
        DataSyncArchiveRemoveResult.preconditionFailed,
      );
      expect(stored, replacement);
    },
  );

  for (final etags in <List<String>?>[
    null,
    ['W/"weak"'],
    ['unquoted'],
    ['*'],
    ['"one"', '"two"'],
    ['"one", "two"'],
  ]) {
    test(
      'GET content without a usable strong ETag remains content evidence: $etags',
      () async {
        final fixture = _Fixture(
          (_) => _response(200, bytes: bytes, headers: {'etag': ?etags}),
        );
        addTearDown(fixture.remote.dispose);
        final result =
            await fixture.remote.probeArchive('oldest.venera')
                as DataSyncArchivePresent;
        expect(result.sha256, hash);
        expect(result.length, bytes.length);
        expect(result.strongEtag, isNull);
        for (final invalid in [
          '',
          '*',
          'W/"weak"',
          'unquoted',
          '"bad\r\ntag"',
        ]) {
          await expectLater(
            fixture.remote.removeArchiveIfUnchanged(
              'oldest.venera',
              strongEtag: invalid,
            ),
            throwsArgumentError,
          );
        }
        expect(fixture.requests, hasLength(1));
      },
    );
  }

  for (final status in [401, 403, 410, 500, 503, 206]) {
    test(
      'GET $status is an error, never missing or complete content',
      () async {
        final fixture = _Fixture((_) => _response(status, bytes: [1, 2, 3]));
        addTearDown(fixture.remote.dispose);
        await expectLater(
          fixture.remote.probeArchive('snapshot.venera'),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              status,
            ),
          ),
        );
        expect(fixture.requests, hasLength(1));
      },
    );
  }

  for (final status in [301, 302, 307, 308]) {
    test(
      'GET PUT DELETE $status cannot redirect outside the endpoint',
      () async {
        final fixture = _Fixture(
          (_) => _response(
            status,
            headers: {
              'location': ['https://other.example.com/stolen.venera'],
            },
          ),
        );
        addTearDown(fixture.remote.dispose);
        for (final operation in <Future<Object?> Function()>[
          () => fixture.remote.probeArchive('Snapshot.venera'),
          () => create(fixture),
          () => fixture.remote.removeArchiveIfUnchanged(
            'Snapshot.venera',
            strongEtag: '"old"',
          ),
          () => fixture.remote.readToFile(
            'Snapshot.venera',
            '${directory.path}/untouched.venera',
          ),
          fixture.remote.listNames,
        ]) {
          await expectLater(
            operation(),
            throwsA(
              isA<DioException>().having(
                (e) => e.response?.statusCode,
                'status',
                status,
              ),
            ),
          );
        }
        expect(fixture.requests, hasLength(5));
        expect(
          fixture.requests.every((r) => r.options.uri.host == 'example.test'),
          isTrue,
        );
        expect(
          fixture.requests.every((r) => !r.options.followRedirects),
          isTrue,
        );
        expect(
          File('${directory.path}/untouched.venera').existsSync(),
          isFalse,
        );
      },
    );
  }

  for (final status in [200, 404]) {
    test('truncated GET $status cannot produce archive evidence', () async {
      final fixture = _Fixture(
        (_) => _response(
          status,
          bytes: [1, 2],
          headers: {
            'content-length': ['3'],
          },
        ),
      );
      addTearDown(fixture.remote.dispose);
      await expectLater(
        fixture.remote.probeArchive('snapshot.venera'),
        throwsFormatException,
      );
    });
  }

  test('GET stream failure cannot become content or missing', () async {
    final failure = StateError('connection reset halfway through response');
    final fixture = _Fixture(
      (_) => ResponseBody(Stream<Uint8List>.error(failure), 200),
    );
    addTearDown(fixture.remote.dispose);
    await expectLater(
      fixture.remote.probeArchive('snapshot.venera'),
      throwsA(
        anyOf(
          same(failure),
          isA<DioException>().having(
            (e) => e.error,
            'stream error',
            same(failure),
          ),
        ),
      ),
    );
  });

  test(
    'GET validates encoding and Content-Length instead of trusting ETag',
    () async {
      final replies = [
        _response(
          200,
          bytes: [1, 2],
          headers: {
            'content-length': ['1'],
          },
        ),
        _response(
          200,
          bytes: [1, 2],
          headers: {
            'content-length': ['invalid'],
          },
        ),
        _response(
          200,
          bytes: [1, 2],
          headers: {
            'content-length': ['2', '2'],
          },
        ),
        _response(
          200,
          bytes: [1, 2],
          headers: {
            'content-encoding': ['gzip'],
          },
        ),
      ];
      final fixture = _Fixture((_) => replies.removeAt(0));
      addTearDown(fixture.remote.dispose);
      for (var i = 0; i < 4; i++) {
        await expectLater(
          fixture.remote.probeArchive('snapshot.venera'),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'GET without Content-Length hashes all chunks and downloads the same bytes',
    () async {
      final fixture = _Fixture(
        (_) => ResponseBody(
          Stream.fromIterable([bytes.sublist(0, 11), bytes.sublist(11)]),
          200,
        ),
      );
      addTearDown(fixture.remote.dispose);
      final evidence =
          await fixture.remote.probeArchive('snapshot.venera')
              as DataSyncArchivePresent;
      expect(evidence.length, bytes.length);
      expect(evidence.sha256, hash);
      final target = File('${directory.path}/nested/download.venera');
      await fixture.remote.readToFile('snapshot.venera', target.path);
      expect(target.readAsBytesSync(), bytes);
    },
  );

  for (final scheme in ['Basic', 'Digest']) {
    test(
      '$scheme challenge retries the entire verified body and keeps scoped conditions',
      () async {
        var authenticated = false;
        final fixture = _Fixture(
          (request) {
            final auth =
                request.options.headers[HttpHeaders.authorizationHeader]
                    as String?;
            if (auth == null) {
              // A retry must use the already verified bytes, even if the source
              // file is subsequently replaced during authentication.
              source.writeAsBytesSync([9, 8, 7]);
              return _response(
                401,
                bytes: utf8.encode('read challenge body before retry'),
                headers: {
                  'www-authenticate': [
                    scheme == 'Basic'
                        ? 'Basic realm="MixedRealm"'
                        : 'Digest realm="MixedRealm", nonce="MixedNonce", qop="auth", algorithm=MD5',
                  ],
                },
              );
            }
            if (scheme == 'Basic') {
              expect(auth, 'Basic ${base64Encode(utf8.encode('user:secret'))}');
            } else {
              _verifyDigest(request, auth);
            }
            authenticated = true;
            if (request.options.method == 'PUT') {
              expect(request.body, bytes);
              expect(
                request.options.headers[HttpHeaders.ifNoneMatchHeader],
                '*',
              );
              return _response(201);
            }
            expect(
              request.options.headers[HttpHeaders.ifNoneMatchHeader],
              isNull,
            );
            return _response(200, bytes: bytes);
          },
          user: 'user',
          password: 'secret',
        );
        addTearDown(fixture.remote.dispose);
        expect(await create(fixture), DataSyncArchiveCreateResult.created);
        expect(authenticated, isTrue);
        expect(fixture.requests.take(2).map((r) => r.body), [bytes, bytes]);
        expect(
          (await fixture.remote.probeArchive('Snapshot.venera')
                  as DataSyncArchivePresent)
              .sha256,
          hash,
        );
        expect(fixture.requests, hasLength(3));
        expect(
          fixture.client.c.options.headers.containsKey(
            HttpHeaders.ifNoneMatchHeader,
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'unauthorized authenticated request stays failed without an infinite retry',
    () async {
      final fixture = _Fixture(
        (_) => _response(
          401,
          headers: {
            'www-authenticate': ['Basic realm="restricted"'],
          },
        ),
        user: 'bad',
        password: 'bad',
      );
      addTearDown(fixture.remote.dispose);
      await expectLater(
        create(fixture),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(fixture.requests, hasLength(2));
      expect(fixture.requests.map((r) => r.body), [bytes, bytes]);
    },
  );

  test(
    'stale Digest challenge refreshes the nonce with a complete conditional retry',
    () async {
      var calls = 0;
      final fixture = _Fixture(
        (request) {
          calls++;
          expect(request.body, bytes);
          expect(request.options.headers[HttpHeaders.ifNoneMatchHeader], '*');
          final auth =
              request.options.headers[HttpHeaders.authorizationHeader]
                  as String?;
          if (calls == 1) {
            expect(auth, isNull);
            return _response(
              401,
              headers: {
                'www-authenticate': [
                  'Digest realm="MixedRealm", nonce="ExpiredNonce", qop="auth", algorithm=MD5',
                ],
              },
            );
          }
          if (calls == 2) {
            expect(auth, contains('nonce="ExpiredNonce"'));
            return _response(
              401,
              headers: {
                'www-authenticate': [
                  'Digest realm="MixedRealm", nonce="MixedNonce", qop="auth", algorithm=MD5, stale=true',
                ],
              },
            );
          }
          _verifyDigest(request, auth!);
          return _response(201);
        },
        user: 'user',
        password: 'secret',
      );
      addTearDown(fixture.remote.dispose);
      expect(await create(fixture), DataSyncArchiveCreateResult.created);
      expect(calls, 3);
    },
  );

  test(
    'failing to open a download destination cancels its response stream',
    () async {
      var cancelled = false;
      final body = StreamController<Uint8List>(
        onCancel: () => cancelled = true,
      );
      final fixture = _Fixture((_) => ResponseBody(body.stream, 200));
      addTearDown(fixture.remote.dispose);
      final blocker = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('keep');
      await expectLater(
        fixture.remote.readToFile(
          'snapshot.venera',
          '${blocker.path}/snapshot.venera',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(cancelled, isTrue);
      expect(blocker.readAsStringSync(), 'keep');
      await body.close();
    },
  );

  test(
    'lost PUT response is surfaced and a complete GET can reconcile its content',
    () async {
      Uint8List? stored;
      final fixture = _Fixture((request) {
        if (request.options.method == 'PUT') {
          stored = request.body;
          throw const SocketException('acknowledgement lost');
        }
        return _response(200, bytes: stored!);
      });
      addTearDown(fixture.remote.dispose);
      await expectLater(create(fixture), throwsA(isA<DioException>()));
      final evidence =
          await fixture.remote.probeArchive('Snapshot.venera')
              as DataSyncArchivePresent;
      expect(evidence.sha256, hash);
      expect(evidence.length, bytes.length);
      expect(fixture.requests.map((r) => r.options.method), ['PUT', 'GET']);
    },
  );

  test(
    'missing conditional DELETE is terminal while other server statuses are errors',
    () async {
      final statuses = [404, 202, 403, 500];
      final fixture = _Fixture((_) => _response(statuses.removeAt(0)));
      addTearDown(fixture.remote.dispose);
      expect(
        await fixture.remote.removeArchiveIfUnchanged(
          'old.venera',
          strongEtag: '"old"',
        ),
        DataSyncArchiveRemoveResult.missing,
      );
      for (final status in [202, 403, 500]) {
        await expectLater(
          fixture.remote.removeArchiveIfUnchanged(
            'old.venera',
            strongEtag: '"old"',
          ),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              status,
            ),
          ),
        );
      }
    },
  );

  test(
    'Digest signs the exact HTTP target for escaped filenames and endpoint query',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      final failures = <Object>[];
      server.listen((request) async {
        try {
          final body = await request.fold<BytesBuilder>(
            BytesBuilder(),
            (all, chunk) => all..add(chunk),
          );
          final authorization = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          if (authorization == null) {
            request.response.statusCode = 401;
            request.response.headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Digest realm="MixedRealm", nonce="MixedNonce", qop="auth", algorithm=MD5',
            );
            request.response.write('challenge');
          } else {
            _verifyDigest((
              options: RequestOptions(
                path: request.uri.toString(),
                method: request.method,
              ),
              body: body.takeBytes(),
            ), authorization);
            seen.add(request.uri.toString());
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          }
        } catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
        } finally {
          await request.response.close();
        }
      });
      final endpoint = WebDavEndpoint(
        url:
            'http://127.0.0.1:${server.port}/dav/Mixed%20Root?token=Mixed%20Token',
        user: 'user',
        password: 'secret',
      );
      final remote = WebDavDataSyncRemote(
        endpoint,
        createClient: (connection) =>
            connection.createClient(adapter: IOHttpClientAdapter()),
      );
      addTearDown(remote.dispose);
      const names = [
        'space name.venera',
        '空白.venera',
        '100%.venera',
        'question?#.venera',
      ];
      for (final name in names) {
        final evidence =
            await remote.probeArchive(name) as DataSyncArchivePresent;
        expect(evidence.sha256, hash);
      }
      expect(failures, isEmpty);
      expect(seen, [
        for (final name in names)
          '/dav/Mixed%20Root/${Uri.encodeComponent(name)}?token=Mixed%20Token',
      ]);
    },
  );
}

ResponseBody _response(
  int status, {
  List<int> bytes = const [],
  Map<String, List<String>> headers = const {},
}) => ResponseBody(
  Stream.value(Uint8List.fromList(bytes)),
  status,
  headers: {
    'content-length': ['${bytes.length}'],
    ...headers,
  },
);

typedef _Request = ({RequestOptions options, Uint8List body});

class _Fixture {
  _Fixture(
    FutureOr<ResponseBody> Function(_Request) respond, {
    String user = '',
    String password = '',
  }) {
    final adapter = _Adapter((request) {
      requests.add(request);
      return respond(request);
    });
    final endpoint = WebDavEndpoint(
      url: 'http://example.test/dav/MixedRoot',
      user: user,
      password: password,
    );
    remote = WebDavDataSyncRemote(
      endpoint,
      createClient: (connection) =>
          client = connection.createClient(adapter: adapter),
    );
  }
  final requests = <_Request>[];
  late final WebDavDataSyncRemote remote;
  late final webdav.Client client;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(_Request) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final builder = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    return respond((options: options, body: builder.takeBytes()));
  }

  @override
  void close({bool force = false}) {}
}

void _verifyDigest(_Request request, String auth) {
  expect(auth, startsWith('Digest '));
  final fields = <String, String>{
    for (final match in RegExp(
      r'(\w+)=(?:"([^"]*)"|([^,\s]+))',
    ).allMatches(auth))
      match[1]!: match[2] ?? match[3]!,
  };
  expect(fields['username'], 'user');
  expect(fields['realm'], 'MixedRealm');
  expect(fields['nonce'], 'MixedNonce');
  final uri = request.options.uri;
  expect(fields['uri'], '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}');
  String digest(String value) => md5.convert(utf8.encode(value)).toString();
  final ha1 = digest('user:MixedRealm:secret');
  final ha2 = digest('${request.options.method}:${fields['uri']}');
  expect(
    fields['response'],
    digest('$ha1:MixedNonce:${fields['nc']}:${fields['cnonce']}:auth:$ha2'),
  );
}
