import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorites_repository.dart';

ImageFavoritesComic comic(
  String id, {
  String source = 'source',
}) => ImageFavoritesComic(
  id,
  [
    ImageFavoritesEp(
      'chapter',
      1,
      [ImageFavorite(1, 'image', null, 'chapter', id, 1, source, 'Chapter')],
      'Chapter',
      12,
    ),
  ],
  'Title $id',
  source,
  ['Tag', '', 'more'],
  ['translated'],
  DateTime.fromMillisecondsSinceEpoch(1234),
  'Author',
  {'custom': 3},
  'Subtitle',
  12,
);

void main() {
  late Database db;
  late ImageFavoritesRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    repository = ImageFavoritesRepository(db);
    repository.initialize();
  });
  tearDown(() => db.dispose());

  test('stored compact legacy rows retain identity, defaults and metadata', () {
    repository.save(comic('shared'));
    repository.save(comic('shared', source: 'other'));
    final row = db.select(
      'SELECT * FROM image_favorites WHERE source_key = ?',
      ['source'],
    ).single;
    final chapters = jsonDecode(row['image_favorites_ep'] as String) as List;
    expect(chapters.single['imageFavorites'], [
      {'page': 1, 'imageKey': 'image'},
    ]);
    (chapters.single as Map).remove('maxPage');
    db.execute(
      'UPDATE image_favorites SET image_favorites_ep = ? WHERE source_key = ?',
      [jsonEncode(chapters), 'source'],
    );
    final loaded = repository.find('shared', 'source')!;
    expect(loaded.imageFavoritesEp.single.maxPage, 1);
    expect(loaded.images.single.id, 'shared');
    expect(loaded.images.single.sourceKey, 'source');
    expect(loaded.images.single.isAutoFavorite, isNull);
    expect(loaded.tags, ['Tag', '', 'more']);
    expect(loaded.translatedTags, ['translated']);
    expect(loaded.other, {'custom': 3});
    expect(loaded.time.millisecondsSinceEpoch, 1234);
    expect(repository.count(), 2);
    expect(repository.find('missing', 'source'), isNull);
    for (final query in [
      'Title',
      'Subtitle',
      'Author',
      'tag',
      'TRANSLATED',
      '%',
    ]) {
      expect(repository.getAll(query), hasLength(2));
    }
    expect(repository.getAll("' OR 1=1 --"), isEmpty);
    loaded.imageFavoritesEp.clear();
    repository.save(loaded);
    expect(repository.find('shared', 'source'), isNull);
    expect(repository.find('shared', 'other'), isNotNull);
  });

  test(
    'chapter and page normalization retains first duplicates and auto flags',
    () {
      final item = comic('book');
      final chapter = item.imageFavoritesEp.single;
      chapter.imageFavorites = [
        ImageFavorite(
          3,
          'first',
          true,
          'chapter',
          'book',
          1,
          'source',
          'Chapter',
        ),
        ImageFavorite(
          3,
          'second',
          false,
          'chapter',
          'book',
          1,
          'source',
          'Chapter',
        ),
        ImageFavorite(
          0,
          'invalid',
          null,
          'chapter',
          'book',
          1,
          'source',
          'Chapter',
        ),
        ImageFavorite(
          2,
          'manual',
          false,
          'chapter',
          'book',
          1,
          'source',
          'Chapter',
        ),
      ];
      item.imageFavoritesEp = [
        ImageFavoritesEp('zero', 0, [], '', 1),
        ImageFavoritesEp('two', 2, [], '', 1),
        chapter,
        ImageFavoritesEp('duplicate', 1, [], '', 1),
      ];
      repository.save(item);
      final loaded = repository.find('book', 'source')!;
      expect(loaded.imageFavoritesEp.map((ep) => ep.ep), [1, 2]);
      expect(loaded.images.map((image) => image.page), [2, 3]);
      expect(loaded.images.map((image) => image.imageKey), ['manual', 'first']);
      expect(loaded.images.map((image) => image.isAutoFavorite), [false, true]);
      expect(item.imageFavoritesEp, hasLength(4));
      expect(chapter.imageFavorites, hasLength(4));
    },
  );

  test(
    'batch failure rolls back earlier deletes and writes and allows retry',
    () {
      repository.saveAll([comic('keep'), comic('fail')]);
      db.execute(
        "CREATE TRIGGER fail_write BEFORE INSERT ON image_favorites WHEN new.id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      final removal = comic('keep')..imageFavoritesEp.clear();
      expect(
        () => repository.saveAll([removal, comic('new'), comic('fail')]),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.getAll().map((item) => item.id).toSet(), {
        'keep',
        'fail',
      });
      db.execute('DROP TRIGGER fail_write;');
      repository.saveAll([removal, comic('new'), comic('fail')]);
      expect(repository.getAll().map((item) => item.id).toSet(), {
        'new',
        'fail',
      });
      final invalid = comic('invalid')
        ..imageFavoritesEp = [ImageFavoritesEp('', 0, [], '', 1)];
      expect(
        () => repository.saveAll([comic('rollback'), invalid]),
        throwsA('Error: No ImageFavoritesEp'),
      );
      expect(repository.find('rollback', 'source'), isNull);
    },
  );
}
