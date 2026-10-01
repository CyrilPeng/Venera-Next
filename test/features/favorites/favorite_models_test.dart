import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorite_row.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test(
    'row decoding preserves legacy timestamp and single-empty tag removal',
    () {
      final db = sqlite3.openInMemory();
      try {
        final row = db.select('''
        SELECT 'book' AS id, 'Title' AS name, 'Author' AS author,
          17 AS type, ',a,,a,' AS tags, 'cover' AS cover_path,
          'legacy timestamp' AS time
      ''').single;
        final item = favoriteItemFromRow(row);
        expect(item.id, 'book');
        expect(item.name, 'Title');
        expect(item.author, 'Author');
        expect(item.type.value, 17);
        expect(item.coverPath, 'cover');
        expect(item.time, 'legacy timestamp');
        expect(item.tags, ['a', '', 'a', '']);
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'legacy JSON source conversion and target fallback remain compatible',
    () {
      for (final (legacy, cover, expected) in [
        (0, 'https://cover', 'picacg'.hashCode),
        (0, '/local/cover', 0),
        (1, 'cover', 'ehentai'.hashCode),
        (2, 'cover', 'jm'.hashCode),
        (3, 'cover', 'hitomi'.hashCode),
        (4, 'cover', 'wnacg'.hashCode),
        (6, 'cover', 'nhentai'.hashCode),
        (5, 'cover', 5),
        (987, 'cover', 987),
      ]) {
        final item = FavoriteItem.fromJson({
          'target': 'old-id',
          'type': legacy,
          'name': 'Title',
          'author': 'Author',
          'coverPath': cover,
        });
        expect(item.id, 'old-id');
        expect(item.type.value, expected);
        expect(item.tags, isEmpty);
      }
    },
  );

  test(
    'new timestamps and exported JSON keep their existing representation',
    () {
      final item = FavoriteItem(
        id: 'book',
        name: 'Title',
        author: 'Author',
        coverPath: 'cover',
        type: ComicType(987),
        tags: ['a', 'a'],
        favoriteTime: DateTime.utc(2026, 10, 1, 2, 3, 4, 567),
      );
      expect(item.time, '2026-10-01 02:03:04');
      expect(item.toJson(), {
        'id': 'book',
        'name': 'Title',
        'author': 'Author',
        'coverPath': 'cover',
        'type': 987,
        'tags': ['a', 'a'],
      });
      final restored = FavoriteItem.fromJson(item.toJson());
      expect(restored, item);
      expect(restored.hashCode, item.hashCode);
      expect(restored.tags, ['a', 'a']);
    },
  );
}
