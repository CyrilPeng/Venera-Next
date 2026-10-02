import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_source/normalization.dart';
import 'package:venera_next/foundation/js_engine.dart';

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
  test('normalize settings filters invalid keys and scopes callbacks', () {
    final callbacks = JsCallbackScope();
    addTearDown(callbacks.dispose);
    final callback = _FakeJSInvokable((args) => 'called:${args.single}');

    final settings = normalizeComicSourceSettings({
      'reader': {'label': 'Reader', 'onTap': callback, 1: 'ignored'},
      2: {'label': 'ignored group'},
      'invalid': 'not a map',
    }, retainCallback: callbacks.retain);
    callback.free(); // Release the caller-owned document reference.

    expect(settings!.keys, ['reader']);
    expect(settings['reader']!.containsKey(1), isFalse);
    expect(settings['reader']!['label'], 'Reader');
    final onTap =
        settings['reader']!['onTap'] as dynamic Function(List<dynamic>);
    expect(onTap(['ok']), 'called:ok');
    expect(callback.destroyCount, 0);
    callbacks.dispose();
    callbacks.dispose();
    expect(callback.destroyCount, 1);
    expect(() => onTap(['late']), throwsStateError);
  });

  test('normalize settings returns null for non-map values', () {
    dynamic Function(List<dynamic>) unexpectedCallback(JSInvokable _) =>
        throw StateError('Invalid settings must not retain callbacks');
    expect(
      normalizeComicSourceSettings(null, retainCallback: unexpectedCallback),
      isNull,
    );
    expect(
      normalizeComicSourceSettings('bad', retainCallback: unexpectedCallback),
      isNull,
    );
  });

  test('normalize loading config accepts dynamically typed map', () {
    final config = normalizeComicSourceLoadingConfig(<dynamic, dynamic>{
      'url': 'https://example.com/image.jpg',
      'headers': {'referer': 'https://example.com'},
    });

    expect(config, {
      'url': 'https://example.com/image.jpg',
      'headers': {'referer': 'https://example.com'},
    });
  });

  test('normalize loading config rejects invalid values', () {
    expect(normalizeComicSourceLoadingConfig(null), isNull);
    expect(normalizeComicSourceLoadingConfig('bad'), isNull);
    expect(
      normalizeComicSourceLoadingConfig(<dynamic, dynamic>{1: 'bad-key'}),
      isNull,
    );
  });

  test('normalize string keyed map accepts dynamic map', () {
    final map = normalizeComicSourceStringKeyedMap(<dynamic, dynamic>{
      'images': ['1.jpg', '2.jpg'],
      'next': 'page-2',
    });

    expect(map, {
      'images': ['1.jpg', '2.jpg'],
      'next': 'page-2',
    });
  });

  test('normalize string keyed map rejects invalid keys', () {
    expect(normalizeComicSourceStringKeyedMap(null), isNull);
    expect(normalizeComicSourceStringKeyedMap('bad'), isNull);
    expect(
      normalizeComicSourceStringKeyedMap(<dynamic, dynamic>{1: 'bad'}),
      isNull,
    );
  });

  test('normalize string list rejects invalid entries', () {
    expect(normalizeComicSourceStringList(['1.jpg', '2.jpg']), [
      '1.jpg',
      '2.jpg',
    ]);
    expect(normalizeComicSourceStringList(null), isNull);
    expect(normalizeComicSourceStringList('bad'), isNull);
    expect(normalizeComicSourceStringList(['1.jpg', 2]), isNull);
  });

  test('normalize comic list accepts dynamic item maps', () {
    final comics = normalizeComicSourceComicList([
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
    expect(normalizeComicSourceComicList(null, 'source'), isNull);
    expect(normalizeComicSourceComicList('bad', 'source'), isNull);
    expect(normalizeComicSourceComicList(['bad'], 'source'), isNull);
    expect(
      normalizeComicSourceComicList([
        <dynamic, dynamic>{1: 'bad'},
      ], 'source'),
      isNull,
    );
  });

  test('normalize comic details accepts nested dynamic maps', () {
    final details = normalizeComicSourceComicDetails(
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
      normalizeComicSourceComicDetails('bad', 'source', 'detail-id'),
      isNull,
    );
    expect(
      normalizeComicSourceComicDetails(
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
      normalizeComicSourceComicDetails(
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
    final result = normalizeComicSourceCommentsResult(<dynamic, dynamic>{
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
    expect(normalizeComicSourceCommentsResult(null), isNull);
    expect(
      normalizeComicSourceCommentsResult(<dynamic, dynamic>{'comments': 'bad'}),
      isNull,
    );
    expect(
      normalizeComicSourceCommentsResult(<dynamic, dynamic>{
        'comments': [
          <dynamic, dynamic>{1: 'bad-key'},
        ],
      }),
      isNull,
    );
  });

  test('normalize archive list accepts dynamic item maps', () {
    final archives = normalizeComicSourceArchiveList([
      <dynamic, dynamic>{
        'title': 'Volume 1',
        'description': 'zip archive',
        'id': 'archive-1',
      },
    ]);

    expect(archives, hasLength(1));
    expect(archives!.single.title, 'Volume 1');
    expect(archives.single.description, 'zip archive');
    expect(archives.single.id, 'archive-1');
  });

  test('normalize archive list rejects invalid data', () {
    expect(normalizeComicSourceArchiveList(null), isNull);
    expect(normalizeComicSourceArchiveList('bad'), isNull);
    expect(
      normalizeComicSourceArchiveList([
        <dynamic, dynamic>{1: 'bad-key'},
      ]),
      isNull,
    );
  });

  test('normalize archive download url requires string', () {
    expect(
      normalizeComicSourceArchiveDownloadUrl('https://example.com/a.zip'),
      'https://example.com/a.zip',
    );
    expect(normalizeComicSourceArchiveDownloadUrl(null), isNull);
    expect(normalizeComicSourceArchiveDownloadUrl(1), isNull);
  });
}
