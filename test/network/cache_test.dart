import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/cache.dart';

void main() {
  NetworkCache cache(Uri uri, int size) {
    return NetworkCache(
      uri: uri,
      requestHeaders: const {},
      responseHeaders: const {},
      data: '',
      time: DateTime.now(),
      size: size,
    );
  }

  test('setCache evicts older entries before exceeding memory limit', () {
    final manager = NetworkCacheManager()..clear();
    final first = Uri.parse('https://example.com/first');
    final second = Uri.parse('https://example.com/second');

    manager.setCache(cache(first, 6 * 1024 * 1024));
    manager.setCache(cache(second, 6 * 1024 * 1024));

    expect(manager.getCache(first), isNull);
    expect(manager.getCache(second), isNotNull);
    expect(manager.size, lessThanOrEqualTo(10 * 1024 * 1024));
  });

  test('setCache replacement keeps size accounting correct', () {
    final manager = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/image');

    manager.setCache(cache(uri, 1024));
    manager.setCache(cache(uri, 2048));

    expect(manager.getCache(uri), isNotNull);
    expect(manager.size, 2048);
  });

  test('setCache skips entries larger than memory limit', () {
    final manager = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/large-image');

    manager.setCache(cache(uri, 11 * 1024 * 1024));

    expect(manager.getCache(uri), isNull);
    expect(manager.size, 0);
  });

  test('setCache removes old entry when replacement is too large', () {
    final manager = NetworkCacheManager()..clear();
    final uri = Uri.parse('https://example.com/image');

    manager.setCache(cache(uri, 1024));
    manager.setCache(cache(uri, 11 * 1024 * 1024));

    expect(manager.getCache(uri), isNull);
    expect(manager.size, 0);
  });
}
