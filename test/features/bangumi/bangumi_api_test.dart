import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';

void main() {
  group('BangumiApi', () {
    test(
      'searches manga subjects with the required authenticated request',
      () async {
        final adapter = QueueAdapter.json([
          (
            200,
            {
              'data': [
                {'id': 1, 'name': 'Manga', 'name_cn': '漫画', 'platform': '漫画'},
                {'id': 2, 'name': 'Unknown platform'},
                {'id': 3, 'name': 'Anime', 'platform': '动画'},
              ],
            },
          ),
        ]);
        final api = BangumiApi(token: 'secret-token', dio: dioWith(adapter));

        final subjects = await api.searchSubjects('keyword');

        expect(subjects.map((subject) => subject.id), [1, 2]);
        expect(subjects.first.title, '漫画');
        final request = adapter.requests.single;
        expect(request.method, 'POST');
        expect(request.path, '/v0/search/subjects');
        expect(request.queryParameters, {'limit': 20});
        expect(request.data, {
          'keyword': 'keyword',
          'sort': 'match',
          'filter': {
            'type': [1],
            'nsfw': true,
          },
        });
        expect(request.headers['Authorization'], 'Bearer secret-token');
        expect(request.headers['Accept'], 'application/json');
        expect(request.extra['maskHeadersInLog'], ['Authorization']);
        expect(request.validateStatus(500), isTrue);
      },
    );

    test(
      'skips malformed subjects without dropping valid search results',
      () async {
        final adapter = QueueAdapter.json([
          (
            200,
            {
              'data': [
                {'id': 1, 'name': 'First', 'platform': '漫画'},
                {'id': 'bad', 'name': 1, 'platform': []},
                {'id': 2, 'name': 'Second', 'platform': '漫画'},
              ],
            },
          ),
        ]);
        final api = BangumiApi(token: 'token', dio: dioWith(adapter));

        final subjects = await api.searchSubjects('keyword');

        expect(subjects.map((subject) => subject.id), [1, 2]);
      },
    );

    test('maps the current user', () async {
      final adapter = QueueAdapter.json([
        (200, {'username': 'alice', 'nickname': 'Alice'}),
      ]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final user = await api.currentUser();

      expect(user.username, 'alice');
      expect(user.nickname, 'Alice');
      expect(adapter.requests.single.path, '/v0/me');
      expect(adapter.requests.single.method, 'GET');
    });

    test('wraps an invalid current user schema in an API exception', () async {
      final adapter = QueueAdapter.json([(200, [])]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      await expectLater(api.currentUser(), throwsA(isA<BangumiApiException>()));
    });

    test('returns a default user for an empty 204 response', () async {
      final adapter = QueueAdapter.json([(204, null)]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final user = await api.currentUser();

      expect(user, const BangumiUser('', ''));
    });

    test('returns no subjects for an empty 205 response', () async {
      final adapter = QueueAdapter.json([(205, null)]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final subjects = await api.searchSubjects('keyword');

      expect(subjects, isEmpty);
    });

    test('gets a subject by its numeric id', () async {
      final adapter = QueueAdapter.json([
        (200, {'id': 123, 'name': 'Original', 'name_cn': '标题'}),
      ]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final subject = await api.getSubject(123);

      expect(subject.id, 123);
      expect(subject.title, '标题');
      expect(adapter.requests.single.path, '/v0/subjects/123');
      expect(adapter.requests.single.method, 'GET');
    });

    test('wraps an invalid subject schema in an API exception', () async {
      final adapter = QueueAdapter.json([
        (200, {'id': 'bad'}),
      ]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      await expectLater(
        api.getSubject(123),
        throwsA(isA<BangumiApiException>()),
      );
    });

    test('returns a default subject for an empty response', () async {
      final adapter = QueueAdapter.json([(200, '')]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final subject = await api.getSubject(123);

      expect(subject.id, 0);
    });

    test(
      'returns null for a missing collection and encodes the username',
      () async {
        final adapter = QueueAdapter.json([
          (404, {'title': 'Not Found'}),
        ]);
        final api = BangumiApi(token: 'token', dio: dioWith(adapter));

        final collection = await api.getCollection('a/b c', 9);

        expect(collection, isNull);
        expect(
          adapter.requests.single.path,
          '/v0/users/a%2Fb%20c/collections/9',
        );
      },
    );

    test('returns a default collection for an empty 204 response', () async {
      final adapter = QueueAdapter.json([(204, null)]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      final collection = await api.getCollection('alice', 9);

      expect(collection, isNotNull);
      expect(collection!.type, 0);
      expect(collection.rate, 0);
      expect(collection.epStatus, 0);
      expect(collection.volStatus, 0);
    });

    test(
      'throws extracted error text for a non-404 collection failure',
      () async {
        final adapter = QueueAdapter.json([
          (403, {'details': 'Access denied'}),
        ]);
        final api = BangumiApi(token: 'token', dio: dioWith(adapter));

        expect(
          () => api.getCollection('alice', 9),
          throwsA(
            isA<BangumiApiException>()
                .having((error) => error.statusCode, 'statusCode', 403)
                .having((error) => error.message, 'message', 'Access denied'),
          ),
        );
      },
    );

    test('creates and patches collections using the supplied fields', () async {
      final adapter = QueueAdapter.json([(200, {}), (200, {})]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));
      final createFields = {'type': 3, 'rate': 8};
      final patchFields = {'ep_status': 12};

      await api.createCollection(42, createFields);
      await api.patchCollection(42, patchFields);

      expect(adapter.requests[0].method, 'POST');
      expect(adapter.requests[0].path, '/v0/users/-/collections/42');
      expect(adapter.requests[0].data, createFields);
      expect(adapter.requests[1].method, 'PATCH');
      expect(adapter.requests[1].path, '/v0/users/-/collections/42');
      expect(adapter.requests[1].data, patchFields);
    });

    test('accepts an empty 204 collection response', () async {
      final adapter = QueueAdapter.json([(204, null)]);
      final api = BangumiApi(token: 'token', dio: dioWith(adapter));

      await expectLater(api.createCollection(42, {'type': 3}), completes);
    });
  });

  test('classifies retryable API failures', () {
    expect(const BangumiApiException(null, 'network').isRetryable, isTrue);
    expect(const BangumiApiException(408, 'timeout').isRetryable, isTrue);
    expect(const BangumiApiException(429, 'limited').isRetryable, isTrue);
    expect(const BangumiApiException(500, 'server').isRetryable, isTrue);
    expect(const BangumiApiException(400, 'bad request').isRetryable, isFalse);
  });

  test('wraps Dio transport failures as retryable API exceptions', () async {
    final api = BangumiApi(token: 'token', dio: dioWith(_ThrowingAdapter()));

    await expectLater(
      api.currentUser(),
      throwsA(
        isA<BangumiApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          isNull,
        ),
      ),
    );
  });
}

Dio dioWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.bgm.tv'));
  dio.httpClientAdapter = adapter;
  return dio;
}

class QueueAdapter implements HttpClientAdapter {
  QueueAdapter.json(Iterable<(int, Object?)> responses)
    : _responses = Queue.of(responses);

  final Queue<(int, Object?)> _responses;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (statusCode, body) = _responses.removeFirst();
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      throw DioException(requestOptions: options, message: 'Connection failed');

  @override
  void close({bool force = false}) {}
}
