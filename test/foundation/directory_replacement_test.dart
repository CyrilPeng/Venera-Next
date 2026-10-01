import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/directory_replacement.dart';

void main() {
  late Directory root;
  late String target;
  late String backup;
  setUp(() {
    root = Directory.systemTemp.createTempSync('directory-replacement-');
    target = '${root.path}/target';
    backup = '${root.path}/backup';
  });
  tearDown(() => root.deleteSync(recursive: true));
  void write(String path, String value) {
    File(path).createSync(recursive: true);
    File(path).writeAsStringSync(value);
  }

  test('restores the complete original tree and removes partial additions', () {
    write('$target/nested/original', 'original');
    final replacement = DirectoryReplacement(target, backup)..backup();
    write('$target/partial', 'partial');
    expect(replacement.backup, throwsStateError);
    replacement.restore();
    expect(File('$target/nested/original').readAsStringSync(), 'original');
    expect(File('$target/partial').existsSync(), isFalse);
    expect(Directory(backup).existsSync(), isFalse);
    expect(replacement.restore, throwsStateError);
  });

  test('missing or wrong-type backup preserves the last remaining target', () {
    write('$target/original', 'original');
    final replacement = DirectoryReplacement(target, backup)..backup();
    write('$target/last', 'keep');
    // Move the backup aside to simulate loss without discarding the fixture.
    Directory(backup).renameSync('${root.path}/saved');
    expect(replacement.restore, throwsStateError);
    expect(File('$target/last').readAsStringSync(), 'keep');
    File(backup).writeAsStringSync('occupied');
    expect(replacement.restore, throwsStateError);
    expect(File('$target/last').readAsStringSync(), 'keep');
    File(backup).deleteSync();
    Directory('${root.path}/saved').renameSync(backup);
    replacement.restore();
    expect(File('$target/original').readAsStringSync(), 'original');
  });

  test(
    'wrong-type target retains backup and permits recovery after repair',
    () {
      write('$target/original', 'original');
      final replacement = DirectoryReplacement(target, backup)..backup();
      File(target).writeAsStringSync('occupied');
      expect(replacement.restore, throwsStateError);
      expect(File(target).readAsStringSync(), 'occupied');
      expect(File('$backup/original').readAsStringSync(), 'original');
      File(target).deleteSync();
      replacement.restore();
      expect(File('$target/original').readAsStringSync(), 'original');
    },
  );

  test('absent original removes only the newly created tree', () {
    final replacement = DirectoryReplacement(target, backup)..backup();
    write('$target/partial', 'partial');
    replacement.restore();
    expect(Directory(target).existsSync(), isFalse);
    expect(Directory(backup).existsSync(), isFalse);
  });

  test('overlapping paths and occupied backup fail before moving original', () {
    write('$target/original', 'keep');
    for (final pair in [
      (target, target),
      (target, '$target/backup'),
      ('$target/child', target),
    ]) {
      expect(() => DirectoryReplacement(pair.$1, pair.$2), throwsArgumentError);
    }
    File(backup).writeAsStringSync('occupied');
    expect(DirectoryReplacement(target, backup).backup, throwsStateError);
    expect(File('$target/original').readAsStringSync(), 'keep');
    expect(File(backup).readAsStringSync(), 'occupied');
    expect(
      DirectoryReplacement(backup, '${root.path}/other').backup,
      throwsStateError,
    );
  });
}
