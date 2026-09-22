import 'dart:typed_data';
import 'dart:convert';

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
      final catalog = await repositories.load(repository);
      expect(catalog.skipped, isEmpty);
      expect(catalog.entries.map((entry) => entry.url), [
        'https://example.test/first.js',
        'https://other.test/second.js',
      ]);
      expect(catalog.entries.map((entry) => entry.key), ['first', 'second']);
    },
  );

  test(
    'invalid entries are skipped and reported instead of failing the catalog',
    () async {
      adapter.body = '''[
      {"key":"good","name":"Good","version":"1.0.0","fileName":"good.js"},
      {"key":"bad-key","name":"Bad","version":"1.0.0","fileName":"bad.js"},
      {"key":"bad-version","name":"Bad","version":"1","fileName":"bad.js"},
      {"key":"missing-target","name":"Bad","version":"1.0.0"},
      {"key":"local-file","name":"Bad","version":"1.0.0","url":"file:///tmp/x.js"}
    ]''';
      final catalog = await repositories.load(repository);
      expect(catalog.entries.map((entry) => entry.key), ['good']);
      expect(catalog.skipped, [
        'bad-key',
        'bad-version',
        'missing-target',
        'local-file',
      ]);
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

  final urlCases =
      <
        ({
          String label,
          String base,
          Map<String, dynamic> entry,
          String expected,
        })
      >[
        (
          label: 'absolute url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': 'https://cdn.test/custom.js'},
          expected: 'https://cdn.test/custom.js',
        ),
        (
          label: 'relative url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': '../scripts/custom.js'},
          expected: 'https://example.test/scripts/custom.js',
        ),
        (
          label: 'root relative path',
          base: 'https://example.test/repo/index.json',
          entry: {'fileName': '/scripts/custom.js'},
          expected: 'https://example.test/scripts/custom.js',
        ),
        (
          label: 'query with slash',
          base: 'https://example.test/repo/index.json?token=a/b',
          entry: {'fileName': 'nested/custom.js'},
          expected: 'https://example.test/repo/nested/custom.js',
        ),
        (
          label: 'scheme relative url',
          base: 'https://example.test/repo/index.json',
          entry: {'url': '//cdn.test/custom.js'},
          expected: 'https://cdn.test/custom.js',
        ),
        (
          label: 'local host and port',
          base: 'http://localhost:8080/index.json',
          entry: {'fileName': 'custom.js'},
          expected: 'http://localhost:8080/custom.js',
        ),
      ];
  for (final sample in urlCases) {
    test('resolves ${sample.label} using URI semantics', () async {
      adapter.body = jsonEncode([
        {
          'name': 'Source',
          'key': 'source',
          'version': '1.0.0',
          'fileName': 'example.js',
          ...sample.entry,
        },
      ]);
      final catalog = await repositories.load(
        SourceRepository(id: 'repo', name: 'Repo', url: sample.base),
      );
      expect(catalog.entries.single.url, sample.expected);
    });
  }

  test('rejects non-HTTP script references before installation', () async {
    adapter.body =
        '[{"key":"source","name":"Source","version":"1.0.0","url":"file:///tmp/source.js"}]';
    await expectLater(repositories.load(repository), throwsA(isA<String>()));
  });

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
