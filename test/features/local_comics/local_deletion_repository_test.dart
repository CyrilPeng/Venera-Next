import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/features/local_comics/local_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';

LocalComic comic(
  String id, {
  int type = 17,
  List<String> chapters = const ['a', 'b'],
}) => LocalComic(
  id: id,
  title: id,
  subtitle: '',
  tags: [],
  directory: id,
  chapters: null,
  cover: '',
  comicType: ComicType(type),
  downloadedChapters: chapters,
  createdAt: DateTime(2026),
);

void main() {
  late Database db;
  late LocalRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    repository = LocalRepository(db)..initialize();
  });
  tearDown(() => db.dispose());

  test(
    'chapter deletion uses current rows and preserves other sources and duplicates',
    () {
      final original = comic('1');
      repository.add(original);
      repository.add(comic('1', chapters: const ['new', 'b']));
      repository.add(comic('1', type: 18));
      repository.removeChapters('1', original.comicType, ['a', 'missing', 'a']);
      expect(repository.find('1', original.comicType)!.downloadedChapters, [
        'new',
        'b',
        'b',
      ]);
      expect(original.downloadedChapters, ['a', 'b']);
      expect(repository.findPageMigration('1', original.comicType), isNotNull);
      repository.removeChapters('1', original.comicType, ['new', 'b']);
      expect(repository.find('1', original.comicType), isNull);
      expect(repository.findPageMigration('1', original.comicType), isNull);
      expect(repository.find('1', const ComicType(18))!.downloadedChapters, [
        'a',
        'b',
      ]);
      expect(repository.findPageMigration('1', const ComicType(18)), isNotNull);
      repository.removeChapters('1', original.comicType, ['a']);
      repository.removeChapters('1', const ComicType(18), []);
      expect(repository.count, 1);
    },
  );

  test(
    'chapter update and last-chapter deletion failures retain data for retry',
    () {
      final item = comic('1');
      repository.add(item);
      db.execute(
        "CREATE TRIGGER reject_update BEFORE UPDATE ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.removeChapters('1', item.comicType, ['a']),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.find('1', item.comicType)!.downloadedChapters, [
        'a',
        'b',
      ]);
      db.execute('DROP TRIGGER reject_update;');
      repository.removeChapters('1', item.comicType, ['a']);
      db.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.removeChapters('1', item.comicType, ['b']),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.find('1', item.comicType)!.downloadedChapters, ['b']);
      expect(repository.findPageMigration('1', item.comicType), isNotNull);
      db.execute('DROP TRIGGER reject_delete;');
      repository.removeChapters('1', item.comicType, ['b']);
      expect(repository.count, 0);
      expect(repository.findPageMigration('1', item.comicType), isNull);
    },
  );

  test(
    'batch failure restores earlier comics and all markers, then retry succeeds',
    () {
      final first = comic('1');
      final second = comic('2');
      repository.add(first);
      repository.add(second);
      repository.add(comic('1', type: 18));
      db.execute(
        "CREATE TRIGGER reject_second BEFORE DELETE ON comics WHEN OLD.id = '2' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.removeAll([first, second]),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.count, 3);
      for (final item in [first, second]) {
        expect(
          repository.findPageMigration(item.id, item.comicType),
          isNotNull,
        );
      }
      db.execute('DROP TRIGGER reject_second;');
      repository.removeAll([first, second, first, comic('missing')]);
      expect(repository.count, 1);
      expect(repository.findPageMigration('1', first.comicType), isNull);
      expect(repository.findPageMigration('2', second.comicType), isNull);
      expect(repository.findPageMigration('1', const ComicType(18)), isNotNull);
      repository.removeAll([]);
    },
  );

  test('deletion scopes do not commit the caller transaction', () {
    final first = comic('1');
    final second = comic('2');
    repository.add(first);
    repository.add(second);
    db.execute('BEGIN;');
    repository.removeChapters('1', first.comicType, ['a']);
    repository.removeAll([second]);
    expect(db.autocommit, isFalse);
    expect(repository.count, 1);
    db.execute('ROLLBACK;');
    expect(repository.count, 2);
    expect(repository.find('1', first.comicType)!.downloadedChapters, [
      'a',
      'b',
    ]);
    expect(repository.findPageMigration('2', second.comicType), isNotNull);
  });
}
