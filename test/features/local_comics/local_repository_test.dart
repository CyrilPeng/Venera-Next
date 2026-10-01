import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_repository.dart';
import 'package:venera_next/features/local_comics/local_sort_type.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test('writes and migration markers commit together without mutating chapters', () {
    final db = sqlite3.openInMemory();
    final repository = LocalRepository(db)..initialize();
    LocalComic comic(String id, List<String> chapters) => LocalComic(
      id: id,
      title: 'Title',
      subtitle: '',
      tags: [],
      directory: 'folder',
      chapters: null,
      cover: '',
      comicType: const ComicType(17),
      downloadedChapters: chapters,
      createdAt: DateTime(2026),
    );
    try {
      repository.initialize();
      db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.add(comic('1', const ['new'])),
        throwsA(isA<SqliteException>()),
      );
      expect(db.select('SELECT * FROM natural_sort_migration;'), isEmpty);
      expect(repository.count, 0);
      db.execute('DROP TRIGGER reject_insert;');
      repository.add(comic('ignored', const ['old']), '1');
      expect(repository.findValidId(const ComicType(17)), '2');
      expect(repository.findValidId(const ComicType(18)), '1');
      final updated = comic('1', const ['new', 'old']);
      repository.add(updated);
      expect(updated.downloadedChapters, ['new', 'old']);
      expect(repository.find('1', const ComicType(17))!.downloadedChapters, [
        'new',
        'old',
        'old',
      ]);
      db.execute(
        "UPDATE natural_sort_migration SET history_time = 99, old_page = 4, new_page = 2;",
      );
      repository.add(comic('1', const []));
      expect(
        db.select('SELECT history_time FROM natural_sort_migration;').single[0],
        99,
      );
      db.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.remove('1', const ComicType(17)),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.count, 1);
      expect(
        db.select('SELECT history_time FROM natural_sort_migration;').single[0],
        99,
      );
      db.execute('DROP TRIGGER reject_delete;');
      repository.remove('1', const ComicType(17));
      expect(repository.count, 0);
      expect(db.select('SELECT * FROM natural_sort_migration;'), isEmpty);
    } finally {
      db.dispose();
    }
  });

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
