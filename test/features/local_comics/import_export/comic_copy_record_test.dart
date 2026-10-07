import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  late Directory root;
  late Directory output;
  late ComicCopyRecord record;
  setUp(() {
    root = Directory.systemTemp.createTempSync('copy-record-');
    output = Directory('${root.path}/output')..createSync();
    record = ComicCopyRecord.prepare(
      output,
      source: '${root.path}/source',
      metadata: 'original metadata',
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  void payload() {
    File('${output.path}/1.jpg').writeAsStringSync('first page', flush: true);
    Directory('${output.path}/chapter').createSync();
    File(
      '${output.path}/chapter/2.jpg',
    ).writeAsStringSync('second page', flush: true);
    Directory('${output.path}/empty').createSync();
  }

  test(
    'reopened completion covers nested files and empty directories',
    () async {
      payload();
      await record.complete();
      final reopened = ComicCopyRecord.read(output);
      await expectLater(reopened.metadata, 'original metadata');
      await expectLater(reopened.intentDigest, record.intentDigest);
      await reopened.verifyComplete();
    },
  );

  test('a partially copied comic cannot be recovered as complete', () async {
    File('${output.path}/1.jpg').writeAsStringSync('first of three pages');
    await expectLater(ComicCopyRecord.exists(output), isTrue);
    await expectLater(
      ComicCopyRecord.read(output).verifyComplete,
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(File('${output.path}/1.jpg').existsSync(), isTrue);
  });

  for (final change in [
    'same-size edit',
    'extra file',
    'missing file',
    'missing directory',
  ]) {
    test('completion rejects $change and preserves evidence', () async {
      payload();
      await record.complete();
      switch (change) {
        case 'same-size edit':
          File('${output.path}/1.jpg').writeAsStringSync('other page');
        case 'extra file':
          File('${output.path}/added.jpg').writeAsStringSync('extra');
        case 'missing file':
          File('${output.path}/chapter/2.jpg').deleteSync();
        case 'missing directory':
          Directory('${output.path}/empty').deleteSync();
      }
      await expectLater(
        ComicCopyRecord.read(output).verifyComplete,
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(ComicCopyRecord.exists(output), isTrue);
    });
  }

  for (final marker in [
    ComicCopyRecord.intentName,
    ComicCopyRecord.completionName,
  ]) {
    test('a truncated $marker cannot authorize recovery', () async {
      payload();
      await record.complete();
      File('${output.path}/$marker').writeAsStringSync('{');
      await expectLater(
        () => ComicCopyRecord.read(output).verifyComplete(),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        File('${output.path}/1.jpg').readAsStringSync(),
        'first page',
      );
    });
  }

  for (final marker in [
    ComicCopyRecord.intentName,
    ComicCopyRecord.completionName,
  ]) {
    test('unknown $marker versions preserve the output', () async {
      payload();
      await record.complete();
      final file = File('${output.path}/$marker');
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      data['version'] = 999;
      file.writeAsStringSync(jsonEncode(data));
      await expectLater(
        () => ComicCopyRecord.read(output).verifyComplete(),
        throwsA(anything),
      );
      await expectLater(File('${output.path}/1.jpg').existsSync(), isTrue);
    });
  }

  test(
    'completion from another intent is rejected without removing it',
    () async {
      payload();
      await record.complete();
      final file = File('${output.path}/${ComicCopyRecord.completionName}');
      final original = file.readAsStringSync();
      final value = jsonDecode(original) as Map<String, dynamic>;
      value['intent'] = 'another operation';
      file.writeAsStringSync(jsonEncode(value));
      await expectLater(
        record.verifyComplete,
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        () => record.removeAfterRegistration('registered row'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(file.existsSync(), isTrue);
      await expectLater(File('${output.path}/1.jpg').existsSync(), isTrue);
    },
  );

  test('old record cannot acknowledge a replacement intent', () async {
    payload();
    await record.complete();
    final file = File('${output.path}/${ComicCopyRecord.intentName}');
    final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    value['source'] = 'a different source';
    file.writeAsStringSync(jsonEncode(value));
    await expectLater(
      () => record.removeAfterRegistration('registered row'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      File('${output.path}/${ComicCopyRecord.completionName}').existsSync(),
      isTrue,
    );
  });

  test('registered acknowledgement removes only recovery files', () async {
    payload();
    await record.complete();
    record.removeAfterRegistration('registered row');
    await expectLater(ComicCopyRecord.exists(output), isFalse);
    await expectLater(
      File('${output.path}/1.jpg').readAsStringSync(),
      'first page',
    );
    await expectLater(
      File('${output.path}/chapter/2.jpg').readAsStringSync(),
      'second page',
    );
    await expectLater(Directory('${output.path}/empty').existsSync(), isTrue);
  });

  test('a moved library retains its relative completion evidence', () async {
    payload();
    await record.complete();
    final moved = output.renameSync('${root.path}/moved');
    await ComicCopyRecord.read(moved).verifyComplete();
  });

  test('a new copy refuses existing recovery files in its source', () async {
    payload();
    final destination = Directory('${root.path}/destination')..createSync();
    final result = await ComicDirectoryCopier().copy([
      output.path,
    ], destination);
    await expectLater(result.copies, isEmpty);
    await expectLater(
      result.failures[output.path]!.cause.toString(),
      contains('Recover the earlier copy'),
    );
    await expectLater(destination.listSync(), isEmpty);
    await expectLater(File('${output.path}/1.jpg').existsSync(), isTrue);
  });

  test(
    'case-changed recovery files cannot look like a legacy directory',
    () async {
      payload();
      File('${output.path}/${ComicCopyRecord.intentName}').renameSync(
        '${output.path}/${ComicCopyRecord.intentName.toUpperCase()}',
      );
      await expectLater(ComicCopyRecord.exists(output), isTrue);
    },
  );

  test('a pending child cannot be copied as an ordinary chapter', () async {
    payload();
    final parent = Directory('${root.path}/source')..createSync();
    output.renameSync('${parent.path}/Chapter');
    final target = Directory('${root.path}/target')..createSync();
    final result = await ComicDirectoryCopier().copy([parent.path], target);
    await expectLater(result.copies, isEmpty);
    await expectLater(
      result.failures[parent.path]!.cause.toString(),
      contains('Recover the earlier copy'),
    );
    await expectLater(target.listSync(), isEmpty);
  });
}
