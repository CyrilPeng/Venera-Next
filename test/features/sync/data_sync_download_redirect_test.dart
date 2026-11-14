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
import 'support/remote_response_fixture.dart';

void main() {
  late Directory directory;
  final bytes = Uint8List.fromList(utf8.encode('archive from signed CDN URL'));
  final hash = sha256.convert(bytes).toString();

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sync-download-redirect-');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  for (final status in [301, 302, 303, 307, 308]) {
    test(
      'GET $status follows a CDN URL without DAV secrets or validators',
      () async {
        final fixture = _Fixture((request) {
          expect(request.method, 'GET');
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          expect(request.headers[HttpHeaders.acceptEncodingHeader], 'identity');
          if (request.uri.host == 'dav.example.test') {
            expect(request.headers[HttpHeaders.authorizationHeader], isNotNull);
            expect(request.uri.path, '/dav/MixedRoot/Snapshot.venera');
            return dataSyncResponse(
              status,
              headers: {
                'location': [
                  'https://cdn.example.test/Download/%E6%96%87%E4%BB%B6?sign=cdn-token',
                ],
              },
            );
          }
          expect(request.uri.host, 'cdn.example.test');
          expect(
            request.uri.toString(),
            'https://cdn.example.test/Download/%E6%96%87%E4%BB%B6?sign=cdn-token',
          );
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            everyElement(isIn(['accept', 'accept-encoding', 'user-agent'])),
          );
          return dataSyncResponse(
            200,
            bytes: bytes,
            headers: {
              'etag': ['"cdn-only-tag"'],
            },
          );
        });
        addTearDown(fixture.remote.dispose);
        fixture.client.auth = const webdav.BasicAuth(
          user: 'user',
          pwd: 'password',
        );
        fixture.client.c.options.headers.addAll({
          'Authorization': 'default-auth-secret',
          'Cookie': 'cookie-secret',
          'Proxy-Authorization': 'proxy-secret',
          'X-Api-Key': 'custom-secret',
          'Referer': 'https://dav.example.test/?token=referer-secret',
          'Host': 'dav.example.test',
        });
        fixture.client.c.options.queryParameters['default'] = 'query-secret';
        final evidence =
            await fixture.remote.probeArchive('Snapshot.venera')
                as DataSyncArchivePresent;
        expect(evidence.sha256, hash);
        expect(evidence.length, bytes.length);
        expect(evidence.strongEtag, isNull);
        final output = File('${directory.path}/download.venera');
        await fixture.remote.readToFile('Snapshot.venera', output.path);
        expect(output.readAsBytesSync(), bytes);
        expect(fixture.requests, hasLength(4));
        expect(fixture.client.c.options.headers['Cookie'], 'cookie-secret');
        expect(
          fixture.client.c.options.queryParameters['default'],
          'query-secret',
        );
      },
    );
  }

  test(
    'relative redirect keeps the method and re-signs the exact Digest target',
    () async {
      final fixture = _Fixture((request) {
        expect(request.method, 'GET');
        final auth = request.headers[HttpHeaders.authorizationHeader] as String;
        final fields = <String, String>{
          for (final match in RegExp(
            r'(\w+)=(?:"([^"]*)"|([^,\s]+))',
          ).allMatches(auth))
            match[1]!: match[2] ?? match[3]!,
        };
        final target = '${request.uri.path}?${request.uri.query}';
        expect(fields['uri'], target);
        String digest(String value) =>
            md5.convert(utf8.encode(value)).toString();
        final ha1 = digest('user:MixedRealm:password');
        final ha2 = digest('GET:$target');
        expect(
          fields['response'],
          digest(
            '$ha1:MixedNonce:${fields['nc']}:${fields['cnonce']}:auth:$ha2',
          ),
        );
        if (request.uri.path == '/dav/MixedRoot/Snapshot.venera') {
          return dataSyncResponse(
            302,
            headers: {
              'location': [
                '../../Download/%E6%96%87%20%25%3F%23.venera?sign=Mixed%20Token',
              ],
            },
          );
        }
        expect(
          request.uri.toString(),
          'https://dav.example.test/Download/%E6%96%87%20%25%3F%23.venera?sign=Mixed%20Token',
        );
        return dataSyncResponse(
          200,
          bytes: bytes,
          headers: {
            'etag': ['"download-tag"'],
          },
        );
      });
      addTearDown(fixture.remote.dispose);
      fixture.client.auth = webdav.DigestAuth(
        user: 'user',
        pwd: 'password',
        dParts: webdav.DigestParts(
          'Digest realm="MixedRealm", nonce="MixedNonce", qop="auth", algorithm=MD5',
        ),
      );
      final evidence =
          await fixture.remote.probeArchive('Snapshot.venera')
              as DataSyncArchivePresent;
      expect(evidence.sha256, hash);
      expect(evidence.strongEtag, isNull);
      expect(fixture.requests, hasLength(2));
    },
  );

  for (final scheme in ['Basic', 'Digest']) {
    test(
      'a CDN $scheme challenge never receives or changes DAV credentials',
      () async {
        final fixture = _Fixture((request) {
          if (request.uri.host == 'dav.example.test') {
            return dataSyncResponse(
              302,
              headers: {
                'location': ['//cdn.example.test/private?sign=token'],
              },
            );
          }
          expect(request.headers[HttpHeaders.authorizationHeader], isNull);
          return dataSyncResponse(
            401,
            headers: {
              'www-authenticate': [
                '$scheme realm="untrusted", nonce="untrusted", qop="auth"',
              ],
            },
          );
        });
        addTearDown(fixture.remote.dispose);
        final originalAuth = fixture.client.auth;
        await expectLater(
          fixture.remote.probeArchive('Snapshot.venera'),
          throwsA(_status(401)),
        );
        expect(fixture.requests, hasLength(2));
        expect(fixture.client.auth, same(originalAuth));
      },
    );
  }

  test(
    'a chain never restores credentials after leaving the DAV origin',
    () async {
      var hop = 0;
      final fixture = _Fixture((request) {
        if (hop++ == 0) {
          expect(request.headers[HttpHeaders.authorizationHeader], isNotNull);
          return dataSyncResponse(
            302,
            headers: {
              'location': ['https://cdn.example.test/link'],
            },
          );
        }
        expect(request.headers[HttpHeaders.authorizationHeader], isNull);
        if (request.uri.host == 'cdn.example.test') {
          return dataSyncResponse(
            307,
            headers: {
              'location': ['https://dav.example.test/Download/snapshot'],
            },
          );
        }
        return dataSyncResponse(200, bytes: bytes);
      });
      addTearDown(fixture.remote.dispose);
      fixture.client.auth = const webdav.BasicAuth(
        user: 'user',
        pwd: 'password',
      );
      expect(
        await fixture.remote.probeArchive('Snapshot.venera'),
        isA<DataSyncArchivePresent>(),
      );
      expect(fixture.requests, hasLength(3));
    },
  );

  test(
    'a different port is a different origin and receives no credentials',
    () async {
      final fixture = _Fixture((request) {
        if (request.uri.port == 443) {
          return dataSyncResponse(
            302,
            headers: {
              'location': ['https://dav.example.test:8443/download'],
            },
          );
        }
        expect(request.headers[HttpHeaders.authorizationHeader], isNull);
        return dataSyncResponse(200, bytes: bytes);
      });
      addTearDown(fixture.remote.dispose);
      fixture.client.auth = const webdav.BasicAuth(
        user: 'user',
        pwd: 'password',
      );
      expect(
        await fixture.remote.probeArchive('Snapshot.venera'),
        isA<DataSyncArchivePresent>(),
      );
      expect(fixture.requests, hasLength(2));
    },
  );

  for (final locations in <List<String>>[
    [],
    [''],
    ['https://first.test/file', 'https://second.test/file'],
    ['http://cdn.example.test/insecure'],
    ['file:///local/file'],
    ['https://user:password@cdn.example.test/file'],
    ['https://[invalid'],
    ['https://cdn.example.test/\\file'],
    ['https://cdn.example.test/\r\nfile'],
  ]) {
    test(
      'unsafe/ambiguous redirect ${jsonEncode(locations)} is not followed',
      () async {
        final fixture = _Fixture(
          (_) => dataSyncResponse(302, headers: {'location': locations}),
        );
        addTearDown(fixture.remote.dispose);
        final output = File('${directory.path}/untouched.venera')
          ..writeAsBytesSync([7]);
        await expectLater(
          fixture.remote.readToFile('Snapshot.venera', output.path),
          throwsA(_status(302)),
        );
        expect(fixture.requests, hasLength(1));
        expect(output.readAsBytesSync(), [7]);
      },
    );
  }

  test(
    'redirect loops and long chains stop without creating an output file',
    () async {
      for (final loop in [true, false]) {
        var hop = 0;
        final fixture = _Fixture(
          (_) => dataSyncResponse(
            302,
            headers: {
              'location': [
                loop
                    ? '/dav/MixedRoot/Snapshot.venera?dav=endpoint-secret'
                    : '/hop-${++hop}',
              ],
            },
          ),
        );
        addTearDown(fixture.remote.dispose);
        final output = File('${directory.path}/absent.venera');
        await expectLater(
          fixture.remote.readToFile('Snapshot.venera', output.path),
          throwsA(_status(302)),
        );
        expect(fixture.requests, hasLength(loop ? 1 : 6));
        expect(output.existsSync(), isFalse);
      }
    },
  );

  for (final status in [206, 403, 404, 410, 500, 503]) {
    test(
      'CDN $status is an error, not a missing or complete DAV archive',
      () async {
        final fixture = _Fixture(
          (request) => request.uri.host == 'dav.example.test'
              ? dataSyncResponse(
                  302,
                  headers: {
                    'location': ['https://cdn.example.test/file'],
                  },
                )
              : dataSyncResponse(status, bytes: [1, 2, 3]),
        );
        addTearDown(fixture.remote.dispose);
        await expectLater(
          fixture.remote.probeArchive('Snapshot.venera'),
          throwsA(_status(status)),
        );
        expect(fixture.requests, hasLength(2));
      },
    );
  }

  test(
    'truncated redirect or download bodies cannot produce archive evidence',
    () async {
      for (final truncatedRedirect in [true, false]) {
        final fixture = _Fixture(
          (request) => request.uri.host == 'dav.example.test'
              ? dataSyncResponse(
                  302,
                  headers: {
                    'location': ['https://cdn.example.test/file'],
                    if (truncatedRedirect) 'content-length': ['10'],
                  },
                )
              : dataSyncResponse(
                  200,
                  bytes: [1, 2],
                  headers: {
                    'content-length': ['10'],
                  },
                ),
        );
        addTearDown(fixture.remote.dispose);
        await expectLater(
          fixture.remote.probeArchive('Snapshot.venera'),
          throwsFormatException,
        );
        expect(fixture.requests, hasLength(truncatedRedirect ? 1 : 2));
      }
    },
  );

  test(
    'real HTTP listing authentication and 302 CDN download work together',
    () async {
      final dav = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => dav.close(force: true));
      addTearDown(() => cdn.close(force: true));
      final requests = <String>[];
      final failures = <Object>[];
      dav.listen((request) async {
        try {
          await request.drain<void>();
          requests.add('${request.method} DAV ${request.uri}');
          final auth = request.headers.value(HttpHeaders.authorizationHeader);
          if (auth == null) {
            request.response.statusCode = 401;
            request.response.headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="DAV"',
            );
          } else {
            expect(auth, 'Basic ${base64Encode(utf8.encode('user:password'))}');
            if (request.method == 'PROPFIND') {
              request.response.statusCode = 207;
              request.response.headers.contentType = ContentType(
                'application',
                'xml',
              );
              request.response.write('''<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/dav/MixedRoot/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/dav/MixedRoot/Snapshot.venera</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>${bytes.length}</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
            } else {
              expect(request.method, 'GET');
              request.response.statusCode = 302;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                'http://127.0.0.1:${cdn.port}/Download/%E6%96%87%E4%BB%B6?sign=token',
              );
            }
          }
        } catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
        } finally {
          await request.response.close();
        }
      });
      cdn.listen((request) async {
        try {
          await request.drain<void>();
          requests.add('${request.method} CDN ${request.uri}');
          expect(request.method, 'GET');
          expect(
            request.uri.toString(),
            '/Download/%E6%96%87%E4%BB%B6?sign=token',
          );
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            isNull,
          );
          expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
          expect(
            request.headers.value(HttpHeaders.acceptEncodingHeader),
            'identity',
          );
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
        } finally {
          await request.response.close();
        }
      });
      final remote = WebDavDataSyncRemote(
        WebDavEndpoint(
          url: 'http://127.0.0.1:${dav.port}/dav/MixedRoot',
          user: 'user',
          password: 'password',
        ),
        createClient: (endpoint) =>
            endpoint.createClient(adapter: IOHttpClientAdapter()),
      );
      addTearDown(remote.dispose);
      expect(await remote.listNames(), ['Snapshot.venera']);
      final output = File('${directory.path}/download.venera');
      await remote.readToFile('Snapshot.venera', output.path);
      expect(output.readAsBytesSync(), bytes);
      expect(requests, [
        'PROPFIND DAV /dav/MixedRoot/',
        'PROPFIND DAV /dav/MixedRoot/',
        'GET DAV /dav/MixedRoot/Snapshot.venera',
        'GET CDN /Download/%E6%96%87%E4%BB%B6?sign=token',
      ]);
      expect(failures, isEmpty);
    },
  );
}

Matcher _status(int status) => isA<DioException>().having(
  (error) => error.response?.statusCode,
  'HTTP status',
  status,
);

class _Fixture {
  _Fixture(FutureOr<ResponseBody> Function(RequestOptions) respond) {
    remote = WebDavDataSyncRemote(
      WebDavEndpoint(
        url: 'https://dav.example.test/dav/MixedRoot?dav=endpoint-secret',
        user: 'user',
        password: 'password',
      ),
      createClient: (endpoint) => client = endpoint.createClient(
        adapter: _Adapter((request) {
          requests.add(request);
          return respond(request);
        }),
      ),
    );
  }
  final requests = <RequestOptions>[];
  late final webdav.Client client;
  late final WebDavDataSyncRemote remote;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
