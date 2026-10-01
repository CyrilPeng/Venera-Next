import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'favorite_models.dart';

/// Decode legacy persisted fields without normalizing their timestamp or tags.
FavoriteItem favoriteItemFromRow(Row row) => FavoriteItem.withTime(
  name: row['name'],
  author: row['author'],
  type: ComicType(row['type']),
  tags: (row['tags'] as String).split(',')..remove(''),
  id: row['id'],
  coverPath: row['cover_path'],
  time: row['time'],
);
