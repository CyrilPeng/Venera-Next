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
      'reader': {'label': 'Reader', 'onTap': callback, 1: 'ignored'},
      2: {'label': 'ignored group'},
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
    final config = debugNormalizeComicSourceLoadingConfig(<dynamic, dynamic>{
      'url': 'https://example.com/image.jpg',
      'headers': {'referer': 'https://example.com'},
    });

    expect(config, {
      'url': 'https://example.com/image.jpg',
      'headers': {'referer': 'https://example.com'},
    });
  });

  test('normalize loading config rejects invalid values', () {
    expect(debugNormalizeComicSourceLoadingConfig(null), isNull);
    expect(debugNormalizeComicSourceLoadingConfig('bad'), isNull);
    expect(
      debugNormalizeComicSourceLoadingConfig(<dynamic, dynamic>{1: 'bad-key'}),
      isNull,
    );
  });

  test('normalize string keyed map accepts dynamic map', () {
    final map = debugNormalizeComicSourceStringKeyedMap(<dynamic, dynamic>{
      'images': ['1.jpg', '2.jpg'],
      'next': 'page-2',
    });

    expect(map, {
      'images': ['1.jpg', '2.jpg'],
      'next': 'page-2',
    });
  });

  test('normalize string keyed map rejects invalid keys', () {
    expect(debugNormalizeComicSourceStringKeyedMap(null), isNull);
    expect(debugNormalizeComicSourceStringKeyedMap('bad'), isNull);
    expect(
      debugNormalizeComicSourceStringKeyedMap(<dynamic, dynamic>{1: 'bad'}),
      isNull,
    );
  });

  test('normalize string list rejects invalid entries', () {
    expect(debugNormalizeComicSourceStringList(['1.jpg', '2.jpg']), [
      '1.jpg',
      '2.jpg',
    ]);
    expect(debugNormalizeComicSourceStringList(null), isNull);
    expect(debugNormalizeComicSourceStringList('bad'), isNull);
    expect(debugNormalizeComicSourceStringList(['1.jpg', 2]), isNull);
  });

  test('normalize comic list accepts dynamic item maps', () {
    final comics = debugNormalizeComicSourceComicList([
      <dynamic, dynamic>{
        'title': 'Comic A',
        'cover': 'cover.jpg',
        'id': 'a',
        'tags': ['tag'],
      },
    ], 'source');

    expect(comics, hasLength(1));
    expect(comics!.single.title, 'Comic A');
    expect(comics.single.sourceKey, 'source');
    expect(comics.single.tags, ['tag']);
  });

  test('normalize comic list rejects invalid item maps', () {
    expect(debugNormalizeComicSourceComicList(null, 'source'), isNull);
    expect(debugNormalizeComicSourceComicList('bad', 'source'), isNull);
    expect(debugNormalizeComicSourceComicList(['bad'], 'source'), isNull);
    expect(
      debugNormalizeComicSourceComicList([
        <dynamic, dynamic>{1: 'bad'},
      ], 'source'),
      isNull,
    );
  });

  test('normalize comic details accepts nested dynamic maps', () {
    final details = debugNormalizeComicSourceComicDetails(
      <dynamic, dynamic>{
        'title': 'Detail',
        'cover': 'cover.jpg',
        'tags': <dynamic, dynamic>{
          'author': ['name'],
          'ignored': 'not-list',
        },
        'thumbnails': ['thumb-1.jpg'],
        'recommend': [
          <dynamic, dynamic>{
            'title': 'Comic A',
            'cover': 'cover-a.jpg',
            'id': 'a',
            'tags': ['tag'],
          },
        ],
        'comments': [
          <dynamic, dynamic>{
            'userName': 'reader',
            'content': 'nice',
            'id': 'comment-1',
          },
        ],
      },
      'source',
      'detail-id',
    );

    expect(details!['sourceKey'], 'source');
    expect(details['comicId'], 'detail-id');

    final comicDetails = ComicDetails.fromJson(details);
    expect(comicDetails.title, 'Detail');
    expect(comicDetails.tags, {
      'author': ['name'],
    });
    expect(comicDetails.thumbnails, ['thumb-1.jpg']);
    expect(comicDetails.recommend!.single.sourceKey, 'source');
    expect(comicDetails.comments!.single.id, 'comment-1');
  });

  test('normalize comic details rejects invalid nested data', () {
    expect(
      debugNormalizeComicSourceComicDetails('bad', 'source', 'detail-id'),
      isNull,
    );
    expect(
      debugNormalizeComicSourceComicDetails(
        {
          'title': 'Detail',
          'cover': 'cover.jpg',
          'tags': <dynamic, dynamic>{
            1: ['bad'],
          },
        },
        'source',
        'detail-id',
      ),
      isNull,
    );
    expect(
      debugNormalizeComicSourceComicDetails(
        {
          'title': 'Detail',
          'cover': 'cover.jpg',
          'tags': <dynamic, dynamic>{
            'author': ['name'],
          },
          'recommend': ['bad'],
        },
        'source',
        'detail-id',
      ),
      isNull,
    );
  });

  test('normalize comments result accepts dynamic comment maps', () {
    final result = debugNormalizeComicSourceCommentsResult(<dynamic, dynamic>{
      'comments': [
        <dynamic, dynamic>{
          'userName': 'reader',
          'content': 'nice',
          'id': 12,
          'time': 1000,
        },
      ],
      'maxPage': 2,
    });

    expect(result!.data['maxPage'], 2);
    expect(result.comments, hasLength(1));
    expect(result.comments.single.userName, 'reader');
    expect(result.comments.single.id, '12');
  });

  test('normalize comments result rejects invalid data', () {
    expect(debugNormalizeComicSourceCommentsResult(null), isNull);
    expect(
      debugNormalizeComicSourceCommentsResult(<dynamic, dynamic>{
        'comments': 'bad',
      }),
      isNull,
    );
    expect(
      debugNormalizeComicSourceCommentsResult(<dynamic, dynamic>{
        'comments': [
          <dynamic, dynamic>{1: 'bad-key'},
        ],
      }),
      isNull,
    );
  });
}
