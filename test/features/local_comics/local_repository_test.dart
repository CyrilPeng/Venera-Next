import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_repository.dart';
import 'package:venera_next/features/local_comics/local_sort_type.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test(
    'local queries retain source identity, sort rules, limits and bound search',
    () {
      final db = sqlite3.openInMemory();
      final repository = LocalRepository(db);
      try {
        db.execute(
          'CREATE TABLE comics (id TEXT, title TEXT, subtitle TEXT, tags TEXT, directory TEXT, chapters TEXT, cover TEXT, comic_type INT, downloadedChapters TEXT, created_at INT, PRIMARY KEY(id, comic_type));',
        );
        for (var i = 0; i < 25; i++) {
          db.execute(
            'INSERT INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
            [
              'shared',
              'Title ${i.toString().padLeft(2, '0')}',
              'Author',
              '["Tag"]',
              'directory-$i',
              'null',
              '',
              i,
              '[]',
              i,
            ],
          );
        }
        expect(repository.count, 25);
        expect(
          repository.find('shared', const ComicType(12))!.directory,
          'directory-12',
        );
        expect(repository.find('missing', const ComicType(12)), isNull);
        expect(repository.findByName('directory-12')!.comicType.value, 12);
        expect(repository.findByName('Title 12')!.comicType.value, 12);
        expect(repository.findByName("' OR 1=1 --"), isNull);
        expect(
          repository.getComics(LocalSortType.timeAsc).first.comicType.value,
          0,
        );
        expect(
          repository.getComics(LocalSortType.timeDesc).first.comicType.value,
          24,
        );
        // Existing name sorting is descending, even though the UI name is neutral.
        expect(
          repository.getComics(LocalSortType.name).first.title,
          'Title 24',
        );
        expect(repository.getRecent(), hasLength(20));
        expect(repository.getRecent().last.comicType.value, 5);
        for (final query in ['Author', 'tag', '%', '']) {
          expect(repository.search(query), hasLength(25));
          expect(repository.search(query).first.comicType.value, 24);
        }
        expect(repository.search("' OR 1=1 --"), isEmpty);
        expect(LocalSortType.fromString('unknown'), LocalSortType.name);
      } finally {
        db.dispose();
      }
    },
  );
}
