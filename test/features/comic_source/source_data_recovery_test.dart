import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_data_journal.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';

import '../../support/source_data_files.dart';

class _InterruptedPrepare extends SourceDataFiles {
  @override
  Future<Directory> prepare(File target, {required String operationId}) async {
    await super.prepare(target, operationId: operationId);
    throw const FileSystemException('prepare completed before failure');
  }
}

void main() {
  late Directory root;
  late ControlledSourceDataFiles files;
  late SourceDataStorage storage;
  setUp(() {
    root = Directory.systemTemp.createTempSync('source-data-recovery-');
    files = ControlledSourceDataFiles();
    storage = SourceDataStorage(files: files);
  });
  tearDown(() => root.delete(recursive: true));

  String database() =>
      '${root.path}/${SourceDataJournal.directoryName}/ownership.sqlite';
  int pending() {
    final db = sqlite3.open(database());
    try {
      return db.select('SELECT COUNT(*) AS count FROM writes').single['count']
          as int;
    } finally {
      db.dispose();
    }
  }

  Future<Directory> leaveResidue({bool beforeReplace = false}) async {
    files.beforeRemoveDirectory = (_) =>
        throw const FileSystemException('cleanup denied');
    if (beforeReplace) {
      files.beforeReplace = (_, _) =>
          throw const FileSystemException('replace denied');
    }
    SourceMutationFailure? failure;
    try {
      await storage.write(root.path, 'one', '{"token":"new"}');
      fail('Expected cleanup failure');
    } on SourceMutationFailure catch (error) {
      failure = error;
    }
    files.beforeRemoveDirectory = null;
    files.beforeReplace = null;
    expect(pending(), 1);
    return Directory(failure.recoveryPath!);
  }

  test(
    'recovery only cleans staging and preserves a later live data file',
    () async {
      final residue = await leaveResidue();
      final live = File('${root.path}/comic_source/one.data');
      await live.writeAsString('{"token":"later"}');
      await const SourceDataStorage().recover(root.path);
      expect(residue.existsSync(), isFalse);
      expect(await live.readAsString(), '{"token":"later"}');
      expect(pending(), 0);
      await storage.recover(root.path);
      expect(await live.readAsString(), '{"token":"later"}');
    },
  );

  test('failed uncommitted save cleanup preserves the old file', () async {
    await storage.write(root.path, 'one', '{"token":"old"}');
    final residue = await leaveResidue(beforeReplace: true);
    await storage.recover(root.path);
    expect(residue.existsSync(), isFalse);
    expect(
      await File('${root.path}/comic_source/one.data').readAsString(),
      '{"token":"old"}',
    );
    expect(pending(), 0);
  });

  test(
    'recovery rejects changed contents and retries after the conflict is removed',
    () async {
      final residue = await leaveResidue();
      final temporary = File('${residue.path}/contents');
      await temporary.writeAsString('unrelated user contents');
      await expectLater(
        storage.recover(root.path),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(await temporary.readAsString(), 'unrelated user contents');
      expect(pending(), 1);
      await temporary.delete();
      await storage.recover(root.path);
      expect(pending(), 0);
    },
  );

  test(
    'recovery accepts an interrupted UTF-8 prefix but preserves unknown siblings',
    () async {
      final residue = await leaveResidue();
      final temporary = File('${residue.path}/contents');
      await temporary.writeAsString('{"token":');
      final other = File('${residue.path}/user-note')
        ..writeAsStringSync('keep');
      await expectLater(
        storage.recover(root.path),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(temporary.existsSync(), isFalse);
      expect(await other.readAsString(), 'keep');
      expect(pending(), 1);
      await other.delete();
      await storage.recover(root.path);
      expect(residue.existsSync(), isFalse);
      expect(pending(), 0);
    },
  );

  test(
    'live ownership prevents another storage instance from recovering its write',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      files.beforeReplace = (_, _) async {
        reached.complete();
        await release.future;
      };
      final writing = storage.write(root.path, 'one', '{"token":"new"}');
      try {
        await reached.future;
        await expectLater(
          const SourceDataStorage().recover(root.path),
          throwsA(isA<SourceMutationFailure>()),
        );
        expect(pending(), 1);
      } finally {
        release.complete();
        await writing;
      }
      expect(pending(), 0);
      await storage.recover(root.path);
    },
  );

  test(
    'missing directory after interrupted acknowledgement is safe to finish',
    () async {
      final residue = await leaveResidue();
      await residue.delete();
      await storage.recover(root.path);
      expect(pending(), 0);
    },
  );

  for (final field in ['data_root', 'digest', 'id']) {
    test('invalid $field retains both journal and staging', () async {
      final residue = await leaveResidue();
      final db = sqlite3.open(database());
      db.execute('UPDATE writes SET $field = ?', ['../outside']);
      db.dispose();
      await expectLater(
        storage.recover(root.path),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(residue.existsSync(), isTrue);
      expect(pending(), 1);
    });
  }

  test(
    'recovery refuses a staging directory replaced by a filesystem alias',
    () async {
      final residue = await leaveResidue();
      await residue.delete();
      final foreign = Directory('${root.path}/foreign')..createSync();
      final keep = File('${foreign.path}/contents')
        ..writeAsStringSync('{"token":"new"}');
      if (Platform.isWindows) {
        final result = await Process.run('cmd', [
          '/c',
          'mklink',
          '/J',
          residue.path.replaceAll('/', '\\'),
          foreign.path.replaceAll('/', '\\'),
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      } else {
        await Link(residue.path).create(foreign.path);
      }
      try {
        await expectLater(
          storage.recover(root.path),
          throwsA(isA<SourceMutationFailure>()),
        );
        expect(await keep.readAsString(), '{"token":"new"}');
        expect(pending(), 1);
      } finally {
        await Link(residue.path).delete();
      }
      await storage.recover(root.path);
      expect(pending(), 0);
    },
  );

  test(
    'failed preparation retains its durable ownership until recovery',
    () async {
      await expectLater(
        SourceDataStorage(
          files: _InterruptedPrepare(),
        ).write(root.path, 'one', '{}'),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(pending(), 1);
      final residue = Directory(
        '${root.path}/comic_source',
      ).listSync().whereType<Directory>().single;
      await storage.recover(root.path);
      expect(residue.existsSync(), isFalse);
      expect(pending(), 0);
    },
  );

  test('legacy unjournaled staging is preserved', () async {
    final legacy = Directory('${root.path}/comic_source/.source-data-legacy')
      ..createSync(recursive: true);
    final file = File('${legacy.path}/contents')..writeAsStringSync('keep');
    await storage.write(root.path, 'one', '{}');
    await storage.recover(root.path);
    expect(await file.readAsString(), 'keep');
    expect(pending(), 0);
  });

  test('only empty orphaned ownership locks are reclaimed', () async {
    await storage.write(root.path, 'one', '{}');
    final directory = '${root.path}/${SourceDataJournal.directoryName}';
    final lock = File('$directory/11111111-1111-4111-8111-111111111111.lock')
      ..writeAsStringSync('');
    final changed = File('$directory/22222222-2222-4222-8222-222222222222.lock')
      ..writeAsStringSync('keep');
    await expectLater(
      storage.recover(root.path),
      throwsA(isA<SourceMutationFailure>()),
    );
    expect(lock.existsSync(), isFalse);
    expect(changed.readAsStringSync(), 'keep');
    await changed.delete();
    await storage.recover(root.path);
  });

  test(
    'a gate conflict closes the live write descriptor and remains retryable',
    () async {
      final gate = File(
        '${root.path}/${SourceDataJournal.directoryName}/access.lock',
      );
      files.beforeRemoveDirectory = (_) async {
        await gate.writeAsString('external data');
        throw const FileSystemException('cleanup failed');
      };
      await expectLater(
        storage.write(root.path, 'one', '{}'),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(pending(), 1);
      await gate.writeAsString('');
      files.beforeRemoveDirectory = null;
      await storage.recover(root.path);
      expect(pending(), 0);
    },
  );
}
