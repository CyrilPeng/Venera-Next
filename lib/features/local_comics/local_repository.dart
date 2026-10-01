import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'local_comic_model.dart';
import 'local_comic_row.dart';
import 'local_sort_type.dart';

/// Local comic queries on a caller-owned connection.
class LocalRepository {
  LocalRepository(this.db);
  final Database db;
  List<LocalComic> getComics(LocalSortType sortType) {
    var res = db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => localComicFromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return localComicFromRow(res.first);
  }

  List<LocalComic> getRecent() {
    final res = db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => localComicFromRow(row)).toList();
  }

  int get count {
    final res = db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return localComicFromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => localComicFromRow(row)).toList();
  }
}
