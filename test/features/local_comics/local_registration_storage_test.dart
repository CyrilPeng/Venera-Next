import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/features/local_comics/local_registration_storage.dart';
import 'package:venera_next/features/local_comics/local_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

void main() {
  late Directory root;
  late Database local;
  late Database favorites;
  late LocalComic comic;
  late FavoriteItem favorite;
  const folder = 'Shelf "quoted"';
  setUp(() {
    root = Directory.systemTemp.createTempSync('local-registration-');
    local = sqlite3.open('${root.path}/local.db');
    favorites = sqlite3.open('${root.path}/favorite.db');
    LocalRepository(local).initialize();
    FavoritesRepository(favorites).createFolder(folder);
    comic = LocalComic(
      id: '1',
      title: 'Book',
      subtitle: 'Author',
      tags: ['a', 'b'],
      directory: 'Book',
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2024, 2, 3),
    );
    favorite = FavoriteItem(
      id: '1',
      name: 'Book',
      coverPath: 'cover.jpg',
      author: 'Author',
      type: ComicType.local,
      tags: ['a', 'b'],
      favoriteTime: comic.createdAt,
    );
  });
  tearDown(() {
    if (!local.autocommit) local.execute('ROLLBACK;');
    local.dispose();
    favorites.dispose();
    root.deleteSync(recursive: true);
  });

  void register({Database? connection, bool append = true}) =>
      registerLocalComicRecords(
        localDatabase: connection ?? local,
        comic: comic,
        id: '1',
        favoritesPath: '${root.path}/favorite.db',
        folder: folder,
        favorite: favorite,
        translatedTags: 'translated',
        append: append,
      );
  void expectCounts(int localCount, int favoriteCount) {
    expect(LocalRepository(local).count, localCount);
    expect(FavoritesRepository(favorites).count(folder), favoriteCount);
    expect(
      local.select('SELECT * FROM natural_sort_migration'),
      hasLength(localCount),
    );
  }

  TypeMatcher<PersistenceFailure> failure(
    PersistenceCommitState state,
    String cause,
  ) => isA<PersistenceFailure>()
      .having((error) => error.commitState, 'state', state)
      .having(
        (error) => error.cause.toString(),
        'original cause',
        contains(cause),
      );

  test('commits both databases with exact metadata and attached schema', () {
    // A matching main table must not intercept any favorite write.
    FavoritesRepository(local).createFolder(folder);
    register();
    expectCounts(1, 1);
    expect(FavoritesRepository(local).count(folder), 0);
    final saved = FavoritesRepository(
      favorites,
    ).findComic(folder, '1', ComicType.local.value)!;
    expect(saved.name, 'Book');
    expect(saved.author, 'Author');
    expect(saved.tags, ['a', 'b']);
    expect(saved.time, favorite.time);
    expect(
      favorites
          .select(
            'SELECT translated_tags, display_order FROM "Shelf ""quoted"""',
          )
          .single
          .values,
      ['translated', 1],
    );
    expect(local.select('PRAGMA database_list').map((row) => row['name']), [
      'main',
    ]);
  });
  for (final target in ['local', 'favorite']) {
    for (final abort in ['ABORT', 'ROLLBACK']) {
      test('$target $abort leaves both stores unchanged', () {
        (target == 'local' ? local : favorites).execute('''
          CREATE TRIGGER fail_insert BEFORE INSERT ON ${target == 'local' ? 'comics' : '"Shelf ""quoted"""'}
          BEGIN SELECT RAISE($abort, 'write rejected'); END;
        ''');
        expect(
          register,
          throwsA(
            failure(PersistenceCommitState.notCommitted, 'write rejected'),
          ),
        );
        expectCounts(0, 0);
        (target == 'local' ? local : favorites).execute(
          'DROP TRIGGER fail_insert',
        );
        register();
        expectCounts(1, 1);
      });
    }
  }
  for (final append in [false, true]) {
    test('preserves favorite order in attached storage; append=$append', () {
      favorite.id = '2';
      FavoritesRepository(favorites).addComic(
        folder,
        favorite,
        translatedTags: 'old',
        append: true,
        order: 5,
      );
      favorite.id = '1';
      register(append: append);
      final rows = favorites.select(
        'SELECT display_order FROM "Shelf ""quoted""" WHERE id = ?',
        ['1'],
      );
      expect(rows.single['display_order'], append ? 6 : 4);
      expectCounts(1, 2);
    });
  }
  test('existing favorite identity is a conflict, never silent reuse', () {
    favorite.name = 'Existing favorite';
    FavoritesRepository(
      favorites,
    ).addComic(folder, favorite, translatedTags: 'old', append: true);
    favorite.name = 'New import';
    expect(
      register,
      throwsA(
        failure(
          PersistenceCommitState.notCommitted,
          'identity is already in use',
        ),
      ),
    );
    expectCounts(0, 1);
    expect(
      FavoritesRepository(
        favorites,
      ).findComic(folder, '1', ComicType.local.value)!.name,
      'Existing favorite',
    );
  });
  test('existing local identity is never replaced', () {
    LocalRepository(local).add(comic);
    expect(
      register,
      throwsA(
        failure(
          PersistenceCommitState.notCommitted,
          'identity is already in use',
        ),
      ),
    );
    expectCounts(1, 0);
  });
  test('mismatched favorite identity rolls back before inserting', () {
    favorite.id = '2';
    expect(
      register,
      throwsA(
        failure(PersistenceCommitState.notCommitted, 'identities must match'),
      ),
    );
    expectCounts(0, 0);
  });
  for (final target in ['local', 'favorite']) {
    test(
      'rejects $target WAL instead of promising cross-database atomicity',
      () {
        (target == 'local' ? local : favorites).execute(
          'PRAGMA journal_mode=WAL;',
        );
        expect(
          register,
          throwsA(
            failure(
              PersistenceCommitState.notCommitted,
              'requires rollback journals',
            ),
          ),
        );
        expectCounts(0, 0);
      },
    );
  }
  test('does not enter or roll back a caller transaction', () {
    local.execute('BEGIN;');
    LocalRepository(local).add(comic);
    expect(
      register,
      throwsA(
        failure(
          PersistenceCommitState.notCommitted,
          'requires its own transaction',
        ),
      ),
    );
    expect(local.autocommit, isFalse);
    expectCounts(1, 0);
  });
  test('BEGIN acknowledgement failure rolls back the acquired transaction', () {
    final proxy = _DatabaseProxy(
      local,
      after: (sql) {
        if (sql == 'BEGIN IMMEDIATE;') {
          throw StateError('begin acknowledgement');
        }
      },
    );
    expect(
      () => register(connection: proxy),
      throwsA(
        failure(PersistenceCommitState.notCommitted, 'begin acknowledgement'),
      ),
    );
    expect(local.autocommit, isTrue);
    expectCounts(0, 0);
  });
  test('COMMIT acknowledgement failure is unknown with both rows retained', () {
    final proxy = _DatabaseProxy(
      local,
      after: (sql) {
        if (sql == 'COMMIT;') throw StateError('commit acknowledgement');
      },
    );
    expect(
      () => register(connection: proxy),
      throwsA(
        failure(PersistenceCommitState.unknown, 'commit acknowledgement'),
      ),
    );
    expectCounts(1, 1);
  });
  test('failed rollback retains the write error and cleanup diagnostics', () {
    favorites.execute(
      '''CREATE TRIGGER reject BEFORE INSERT ON "Shelf ""quoted"""
      BEGIN SELECT RAISE(ABORT, 'favorite rejected'); END;''',
    );
    final proxy = _DatabaseProxy(
      local,
      before: (sql) {
        if (sql == 'ROLLBACK;') throw StateError('rollback rejected');
      },
    );
    expect(
      () => register(connection: proxy),
      throwsA(
        failure(PersistenceCommitState.unknown, 'favorite rejected').having(
          (error) => error.cleanupFailures
              .map((failure) => failure.error.toString())
              .join(';'),
          'cleanup',
          contains('rollback rejected'),
        ),
      ),
    );
    expect(local.autocommit, isFalse);
    local.execute('ROLLBACK;');
    expectCounts(0, 0);
  });
  test('failed detach after commit cannot turn success into non-commit', () {
    final proxy = _DatabaseProxy(
      local,
      after: (sql) {
        if (sql == 'DETACH DATABASE registration_favorites;') {
          throw StateError('detach acknowledgement');
        }
      },
    );
    expect(
      () => register(connection: proxy),
      throwsA(
        failure(PersistenceCommitState.committed, 'detach acknowledgement'),
      ),
    );
    expectCounts(1, 1);
  });
}

class _DatabaseProxy extends Fake implements Database {
  _DatabaseProxy(this.actual, {this.before, this.after});
  final Database actual;
  final void Function(String sql)? before;
  final void Function(String sql)? after;
  @override
  bool get autocommit => actual.autocommit;
  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    before?.call(sql);
    actual.execute(sql, parameters);
    after?.call(sql);
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      actual.select(sql, parameters);
}
