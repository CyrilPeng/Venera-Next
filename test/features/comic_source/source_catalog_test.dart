import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';

void main() {
  const repository = SourceRepository(
    id: 'repo',
    name: 'Repo',
    url: 'https://example.test/catalog/index.json',
  );
  late _Response adapter;
  late SourceRepositories repositories;
  setUp(() {
    adapter = _Response();
    repositories = SourceRepositories.forTesting(
      Dio()..httpClientAdapter = adapter,
    );
  });
  tearDown(() => repositories.dispose());

  test(
    'catalog resolves relative scripts against the current repository URL',
    () async {
      adapter.body = '''[
      {"key":"first","name":"First","version":"1.0.0","fileName":"../first.js"},
      {"key":"second","name":"Second","version":"2.0.0","url":"https://other.test/second.js"}
    ]''';
      final entries = await repositories.load(repository);
      expect(entries.map((entry) => entry.url), [
        'https://example.test/first.js',
        'https://other.test/second.js',
      ]);
      expect(entries.map((entry) => entry.key), ['first', 'second']);
    },
  );

  for (final malformed in [
    'not JSON',
    '{}',
    '[{"key":"bad-key","name":"Bad","version":"1.0.0","fileName":"bad.js"}]',
    '[{"key":"bad","name":"Bad","version":"1","fileName":"bad.js"}]',
    '[{"key":"bad","name":"Bad","version":"1.0.0"}]',
  ]) {
    test('invalid catalog is rejected: $malformed', () async {
      adapter.body = malformed;
      await expectLater(repositories.load(repository), throwsA(isA<String>()));
    });
  }

  test('HTTP errors cannot produce an empty successful catalog', () async {
    adapter.status = 503;
    adapter.body = '[]';
    await expectLater(
      repositories.load(repository),
      throwsA(isA<DioException>()),
    );
  });
}

class _Response implements HttpClientAdapter {
  String body = '[]';
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(body, status);
  @override
  void close({bool force = false}) {}
}
