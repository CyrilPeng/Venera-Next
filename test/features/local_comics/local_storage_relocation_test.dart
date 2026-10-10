import 'import_export/legacy_copy_fixture.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_metadata.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/features/local_comics/local_repository.dart';
import 'package:venera_next/features/local_comics/local_storage_migration.dart';
import 'package:venera_next/features/local_comics/local_storage_relocation.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory destination;
  late File mirror;
  late Database db;
  late LocalRepository repository;
  late LocalStorageRelocation relocation;
  late String published;
  late List<Object> errors;

  LocalComic comic(String id, String directory) => LocalComic(
    id: id,
    title: id,
    subtitle: '',
    tags: ['retained'],
    directory: directory,
    chapters: null,
    cover: '1.jpg',
    comicType: ComicType.local,
    downloadedChapters: [],
    createdAt: DateTime(2024),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('relocation-');
    source = Directory(p.join(root.path, 'source'))..createSync();
    destination = Directory(p.join(root.path, 'destination'))..createSync();
    final book = Directory(p.join(source.path, 'book'))..createSync();
    File(p.join(book.path, '1.jpg')).writeAsStringSync('retained page');
    mirror = File(p.join(root.path, 'local_path'))
      ..writeAsStringSync(source.path);
    db = sqlite3.open(p.join(root.path, 'local.db'));
    repository = LocalRepository(db)..initialize();
    repository.add(comic('1', book.path));
    relocation = LocalStorageRelocation(db)..initialize();
    published = source.path;
    errors = [];
  });
  tearDown(() {
    db.dispose();
    root.deleteSync(recursive: true);
  });

  LocalStorageMigration service({
    LocalStorageRelocation? journal,
    Future<void> Function(Directory, Directory)? copy,
    Future<void> Function(LocalComic)? ownership,
  }) => LocalStorageMigration(
    relocation: journal ?? relocation,
    copyContents: copy ?? copyDirectory,
    publishPath: (value) => published = value,
    reportCleanupError: (error, stack) => errors.add(error),
    checkCopyOwnership: ownership,
  );
  Future<String?> move(LocalStorageMigration migration) => migration.migrate(
    source: source,
    destination: destination,
    pathFile: mirror,
  );
  Future<String> prepare() async {
    final snapshot = relocation.snapshot();
    final targets = await relocation.destinations(
      source.path,
      destination.path,
      resolvePath: (value) async => value,
    );
    await copyDirectory(source, destination);
    relocation.prepare(source.path, destination.path, snapshot, targets);
    return snapshot;
  }

  String stored() => repository.find('1', ComicType.local)!.directory;
  void bothCopies() {
    for (final library in [source, destination]) {
      expect(
        File(p.join(library.path, 'book', '1.jpg')).readAsStringSync(),
        'retained page',
      );
    }
  }

  void reopen() {
    db.dispose();
    db = sqlite3.open(p.join(root.path, 'local.db'));
    repository = LocalRepository(db);
    relocation = LocalStorageRelocation(db);
  }

  test(
    'moves absolute and nested references and preserves external and legacy names',
    () async {
      repository.add(comic('relative', 'book'));
      repository.add(comic('nested', p.join(source.path, 'parent', 'child')));
      final external = '${source.path}-external';
      Directory(external).createSync();
      repository.add(comic('external', external));
      expect(await move(service()), isNull);
      expect(stored(), p.join(destination.path, 'book'));
      expect(repository.find('relative', ComicType.local)!.directory, 'book');
      expect(
        repository.find('nested', ComicType.local)!.directory,
        p.join(destination.path, 'parent', 'child'),
      );
      expect(repository.find('external', ComicType.local)!.directory, external);
      expect(published, destination.path);
      expect(mirror.readAsStringSync(), destination.path);
      expect(source.listSync(), isEmpty);
      expect(relocation.pending, isNull);
    },
  );

  test(
    'SAF references keep their provider prefix through directory mapping',
    () async {
      const oldRoot = 'content://provider/tree/primary%3Aold';
      const newRoot = 'content://provider/tree/primary%3Anew';
      final oldBook = p.join(oldRoot, 'Book');
      db.execute('DELETE FROM comics');
      repository.add(comic('1', oldBook));
      repository.add(comic('2', 'Relative'));
      repository.add(comic('3', 'content://other/tree/primary%3Aoutside/Book'));
      final snapshot = relocation.snapshot();
      final targets = await relocation.destinations(
        oldRoot,
        newRoot,
        resolvePath: (value) async => value,
      );
      expect(targets, {oldBook: p.join(newRoot, 'Book')});
      // This checks the path protocol with an identity adapter, not a SAF device.
      relocation.prepare(oldRoot, newRoot, snapshot, targets);
      relocation.commit(snapshot);
      expect(stored(), p.join(newRoot, 'Book'));
      expect(relocation.pending!.destination, newRoot);
      expect(repository.find('2', ComicType.local)!.directory, 'Relative');
      expect(
        repository.find('3', ComicType.local)!.directory,
        'content://other/tree/primary%3Aoutside/Book',
      );
    },
  );

  test('copy failure never prepares or commits directory updates', () async {
    final error = StateError('partial copy');
    await expectLater(
      move(
        service(
          copy: (old, target) async {
            await copyDirectory(old, target);
            throw error;
          },
        ),
      ),
      throwsA(same(error)),
    );
    expect(stored(), p.join(source.path, 'book'));
    expect(relocation.pending, isNull);
    bothCopies();
  });

  test(
    'directory changes while copying reject commit and keep both copies',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final moving = move(
        service(
          copy: (old, target) async {
            await copyDirectory(old, target);
            entered.complete();
            await resume.future;
          },
        ),
      );
      final checked = expectLater(moving, throwsStateError);
      await entered.future;
      repository.add(comic('new', 'other'));
      resume.complete();
      await checked;
      expect(relocation.pending, isNull);
      expect(stored(), p.join(source.path, 'book'));
      expect(published, source.path);
      bothCopies();
    },
  );

  test(
    'prepared recovery reopens the old library and retains the copied target',
    () async {
      await prepare();
      reopen();
      expect(await service().recover(mirror), source.path);
      expect(stored(), p.join(source.path, 'book'));
      expect(mirror.readAsStringSync(), source.path);
      expect(relocation.pending, isNull);
      bothCopies();
    },
  );

  test(
    'committed recovery mirrors the new root without clearing the old copy',
    () async {
      relocation.commit(await prepare());
      expect(mirror.readAsStringSync(), source.path);
      reopen();
      expect(await service().recover(mirror), destination.path);
      expect(stored(), p.join(destination.path, 'book'));
      expect(mirror.readAsStringSync(), destination.path);
      expect(relocation.pending, isNull);
      bothCopies();
    },
  );

  test(
    'mirror failure retains committed authority and survives another failed recovery',
    () async {
      mirror.deleteSync();
      Directory(mirror.path).createSync();
      await expectLater(move(service()), throwsA(isA<FileSystemException>()));
      expect(published, destination.path);
      expect(stored(), p.join(destination.path, 'book'));
      expect(relocation.pending!.committed, isTrue);
      reopen();
      expect(await service().recover(mirror), destination.path);
      expect(errors, hasLength(1));
      expect(relocation.pending!.committed, isTrue);
      Directory(mirror.path).deleteSync();
      expect(await service().recover(mirror), destination.path);
      expect(relocation.pending, isNull);
      bothCopies();
    },
  );

  for (final committed in [false, true]) {
    test(
      'missing ${committed ? 'committed target' : 'prepared source'} refuses recovery',
      () async {
        final snapshot = await prepare();
        if (committed) relocation.commit(snapshot);
        (committed ? destination : source).deleteSync(recursive: true);
        reopen();
        await expectLater(
          service().recover(mirror),
          throwsA(isA<FileSystemException>()),
        );
        expect(relocation.pending, isNotNull);
        expect(mirror.readAsStringSync(), source.path);
      },
    );
  }

  test(
    'prepared recovery rejects an independently changed path mirror',
    () async {
      await prepare();
      mirror.writeAsStringSync(destination.path);
      await expectLater(service().recover(mirror), throwsStateError);
      expect(relocation.pending!.committed, isFalse);
      bothCopies();
    },
  );

  test(
    'SQL failure rolls back every directory update and leaves prepared recovery',
    () async {
      repository.add(comic('2', p.join(source.path, 'second')));
      final snapshot = await prepare();
      db.execute(
        "CREATE TRIGGER fail_move BEFORE UPDATE OF directory ON comics WHEN OLD.id = '2' BEGIN SELECT RAISE(ABORT, 'stop move'); END",
      );
      expect(
        () => relocation.commit(snapshot),
        throwsA(isA<SqliteException>()),
      );
      expect(stored(), p.join(source.path, 'book'));
      expect(
        repository.find('2', ComicType.local)!.directory,
        p.join(source.path, 'second'),
      );
      expect(relocation.pending!.committed, isFalse);
      reopen();
      expect(await service().recover(mirror), source.path);
      bothCopies();
    },
  );

  test(
    'changed snapshot after preparation refuses the final transaction',
    () async {
      final snapshot = await prepare();
      repository.add(comic('2', 'other'));
      expect(() => relocation.commit(snapshot), throwsStateError);
      expect(stored(), p.join(source.path, 'book'));
      expect(relocation.pending!.committed, isFalse);
    },
  );

  test(
    'directory commit cannot be hidden inside an uncommitted outer transaction',
    () async {
      final snapshot = await prepare();
      db.execute('BEGIN');
      expect(() => relocation.commit(snapshot), throwsStateError);
      db.execute('ROLLBACK');
      expect(relocation.pending!.committed, isFalse);
      expect(stored(), p.join(source.path, 'book'));
    },
  );

  for (final failRead in [false, true]) {
    test(
      'commit acknowledgement error preserves original failure${failRead ? ' when reconciliation also fails' : ''}',
      () async {
        var commits = 0;
        var committed = false;
        final error = StateError('commit acknowledgement');
        final lookupError = StateError('journal unavailable');
        final proxy = _DatabaseProxy(
          db,
          after: (sql) {
            if (sql == 'COMMIT;' && ++commits == 2) {
              committed = true;
              throw error;
            }
          },
          beforeSelect: (sql) {
            if (committed && failRead) throw lookupError;
          },
        );
        await expectLater(
          move(service(journal: LocalStorageRelocation(proxy))),
          throwsA(same(error)),
        );
        expect(stored(), p.join(destination.path, 'book'));
        expect(relocation.pending!.committed, isTrue);
        expect(published, failRead ? source.path : destination.path);
        expect(errors, failRead ? [lookupError] : isEmpty);
        bothCopies();
        reopen();
        expect(await service().recover(mirror), destination.path);
      },
    );
  }

  test(
    'a resumed move recovers the authoritative root before accepting a new source',
    () async {
      relocation.commit(await prepare());
      final next = Directory(p.join(root.path, 'next'))..createSync();
      expect(
        await service().migrate(
          source: source,
          destination: next,
          pathFile: mirror,
        ),
        isNotNull,
      );
      expect(published, destination.path);
      expect(next.listSync(), isEmpty);
      bothCopies();
    },
  );

  Future<void> receipt() async {
    final original = repository.find('1', ComicType.local)!;
    final directory = Directory(original.directory);
    final record = prepareLegacyComicCopy(
      directory,
      source: 'import source',
      metadata: encodeComicCopyMetadata(original, null),
    );
    await record.complete();
    final intent = File(
      p.join(directory.path, ComicCopyRecord.intentName),
    ).readAsStringSync();
    // A persisted receipt after registration and before deleting the originals.
    File(
      p.join(directory.path, ComicCopyRecord.registrationName),
    ).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'intent': intent,
        'registration': comicCopyRegistration(original),
      }),
      flush: true,
    );
  }

  test(
    'relocation retires the old receipt using the committed registration',
    () async {
      await receipt();
      var checked = 0;
      expect(
        await move(
          service(
            ownership: (comic) async {
              checked++;
              expect(comic.directory, p.join(destination.path, 'book'));
              expect(published, destination.path);
            },
          ),
        ),
        isNull,
      );
      expect(checked, 1);
      expect(ComicCopyRecord.exists(Directory(stored())), isFalse);
      expect(
        File(p.join(stored(), '1.jpg')).readAsStringSync(),
        'retained page',
      );
      expect(repository.count, 1);
    },
  );

  test(
    'receipt ownership failure remains recoverable after reopening',
    () async {
      await receipt();
      final error = StateError('shared directory');
      await expectLater(
        move(service(ownership: (_) async => throw error)),
        throwsA(same(error)),
      );
      expect(relocation.pending!.committed, isTrue);
      expect(ComicCopyRecord.exists(Directory(stored())), isTrue);
      bothCopies();
      reopen();
      expect(
        await service(ownership: (_) async {}).recover(mirror),
        destination.path,
      );
      expect(relocation.pending, isNull);
      expect(ComicCopyRecord.exists(Directory(stored())), isFalse);
      bothCopies();
    },
  );

  test('receipt plan is not forgotten without an ownership adapter', () async {
    await receipt();
    await expectLater(move(service()), throwsStateError);
    expect(relocation.pending!.cleanups, hasLength(1));
    bothCopies();
  });

  test('changed row after ownership wait blocks receipt removal', () async {
    await receipt();
    await expectLater(
      move(
        service(
          ownership: (_) async {
            db.execute("UPDATE comics SET title = 'changed' WHERE id = '1'");
          },
        ),
      ),
      throwsStateError,
    );
    expect(ComicCopyRecord.exists(Directory(stored())), isTrue);
    expect(relocation.pending, isNotNull);
    bothCopies();
  });

  final invalidStates = <String, Object?>{
    'version': 9,
    'committed': 2,
    'source': 'relative',
    'destination': 'relative',
    'references_json': '{}',
    'cleanups_json': '[{}]',
  };
  for (final entry in invalidStates.entries) {
    test(
      'invalid journal ${entry.key} cannot change the path or remove evidence',
      () async {
        await prepare();
        db.execute('UPDATE local_storage_relocation SET ${entry.key} = ?', [
          entry.value,
        ]);
        await expectLater(
          service().recover(mirror),
          throwsA(isA<FormatException>()),
        );
        expect(published, source.path);
        expect(mirror.readAsStringSync(), source.path);
        expect(
          db.select('SELECT * FROM local_storage_relocation'),
          hasLength(1),
        );
        bothCopies();
      },
    );
  }

  for (final scenario in [
    'overlap',
    'escape',
    'duplicate',
    'receipt mismatch',
  ]) {
    test('rejects journal $scenario before publishing a root', () async {
      await receipt();
      await prepare();
      final state = relocation.pending!;
      if (scenario == 'overlap') {
        db.execute('UPDATE local_storage_relocation SET destination = ?', [
          source.path,
        ]);
      } else if (scenario == 'receipt mismatch') {
        final cleanups = [Map<String, dynamic>.from(state.cleanups.single)];
        cleanups.single['directory'] = source.path;
        db.execute('UPDATE local_storage_relocation SET cleanups_json = ?', [
          jsonEncode(cleanups),
        ]);
      } else {
        final references = [List<Object?>.from(state.references.single)];
        if (scenario == 'escape') {
          references.single[3] = p.join(destination.path, '..', 'outside');
        }
        if (scenario == 'duplicate') references.add(references.single);
        db.execute('UPDATE local_storage_relocation SET references_json = ?', [
          jsonEncode(references),
        ]);
      }
      await expectLater(
        service().recover(mirror),
        throwsA(isA<FormatException>()),
      );
      expect(published, source.path);
      bothCopies();
    });
  }
}

class _DatabaseProxy extends Fake implements Database {
  _DatabaseProxy(this.actual, {this.after, this.beforeSelect});
  final Database actual;
  final void Function(String)? after;
  final void Function(String)? beforeSelect;
  @override
  bool get autocommit => actual.autocommit;
  @override
  int get updatedRows => actual.updatedRows;
  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    actual.execute(sql, parameters);
    after?.call(sql);
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    beforeSelect?.call(sql);
    return actual.select(sql, parameters);
  }
}
