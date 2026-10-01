import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_replacement.dart';

void main() {
  late Directory root;
  late String target;
  late String backup;
  setUp(() {
    root = Directory.systemTemp.createTempSync('file-replacement-');
    target = '${root.path}/target';
    backup = '${root.path}/backup';
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('restore keeps original bytes and commit removes only the backup', () {
    File(target).writeAsStringSync('original');
    final first = FileReplacement(target, backup)..backup();
    File(target).writeAsStringSync('partial');
    first.restore();
    expect(File(target).readAsStringSync(), 'original');
    expect(File(backup).existsSync(), isFalse);
    final second = FileReplacement(target, backup)..backup();
    File(target).writeAsStringSync('complete');
    second.commit();
    expect(File(target).readAsStringSync(), 'complete');
    expect(File(backup).existsSync(), isFalse);
  });

  test('restore of a missing original removes the newly created file', () {
    final replacement = FileReplacement(target, backup)..backup();
    File(target).writeAsStringSync('partial');
    replacement.restore();
    expect(File(target).existsSync(), isFalse);
  });

  test('missing backup never causes deletion of the remaining target', () {
    File(target).writeAsStringSync('original');
    final replacement = FileReplacement(target, backup)..backup();
    File(target).writeAsStringSync('last remaining copy');
    File(backup).deleteSync();
    expect(replacement.restore, throwsStateError);
    expect(File(target).readAsStringSync(), 'last remaining copy');
  });

  test('failed rename retains backup and refuses an existing backup', () {
    File(target).writeAsStringSync('original');
    final replacement = FileReplacement(target, backup)..backup();
    Directory(target).createSync();
    File('$target/keep').writeAsStringSync('keep');
    expect(replacement.restore, throwsA(isA<FileSystemException>()));
    expect(File(backup).readAsStringSync(), 'original');
    expect(
      FileReplacement('${root.path}/other', backup).backup,
      throwsStateError,
    );
    expect(File('$target/keep').readAsStringSync(), 'keep');
  });
}
