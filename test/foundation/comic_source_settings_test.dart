import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';

class _FakeJSInvokable extends JSInvokable {
  _FakeJSInvokable(this.callback);

  final dynamic Function(List args) callback;

  int destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    return callback(args);
  }

  @override
  void destroy() {
    destroyCount++;
  }
}

void main() {
  test('normalize settings filters invalid keys and wraps callbacks', () {
    final callback = _FakeJSInvokable((args) => 'called:${args.single}');

    final settings = debugNormalizeComicSourceSettings({
      'reader': {
        'label': 'Reader',
        'onTap': callback,
        1: 'ignored',
      },
      2: {
        'label': 'ignored group',
      },
      'invalid': 'not a map',
    });

    expect(settings!.keys, ['reader']);
    expect(settings['reader']!.containsKey(1), isFalse);
    expect(settings['reader']!['label'], 'Reader');
    expect(settings['reader']!['onTap'], isA<JSAutoFreeFunction>());

    final onTap = settings['reader']!['onTap'] as JSAutoFreeFunction;
    expect(onTap(['ok']), 'called:ok');
    expect(callback.destroyCount, 0);
  });

  test('normalize settings returns null for non-map values', () {
    expect(debugNormalizeComicSourceSettings(null), isNull);
    expect(debugNormalizeComicSourceSettings('bad'), isNull);
  });

  test('normalize loading config accepts dynamically typed map', () {
    final config = debugNormalizeComicSourceLoadingConfig(
      <dynamic, dynamic>{
        'url': 'https://example.com/image.jpg',
        'headers': {'referer': 'https://example.com'},
      },
    );

    expect(config, {
      'url': 'https://example.com/image.jpg',
      'headers': {'referer': 'https://example.com'},
    });
  });

  test('normalize loading config rejects invalid values', () {
    expect(debugNormalizeComicSourceLoadingConfig(null), isNull);
    expect(debugNormalizeComicSourceLoadingConfig('bad'), isNull);
    expect(
      debugNormalizeComicSourceLoadingConfig(<dynamic, dynamic>{
        1: 'bad-key',
      }),
      isNull,
    );
  });
}
