import 'legacy_copy_fixture.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
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
    record = prepareLegacyComicCopy(
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

  Future<ComicCopyRecord> resumable() async {
    final source = Directory('${root.path}/source')..createSync();
    File('${source.path}/1.jpg').writeAsStringSync('first page');
    Directory('${source.path}/chapter').createSync();
    File('${source.path}/chapter/2.jpg').writeAsStringSync('second page');
    Directory('${source.path}/empty').createSync();
    final destination = Directory('${root.path}/resumable')..createSync();
    return ComicCopyRecord.prepare(destination, source: source);
  }

  test(
    'a thousand-page copy uses bounded listings and checks missing bytes only when copied',
    () async {
      const pageCount = 1000;
      final source = Directory('${root.path}/large-source')..createSync();
      final destination = Directory('${root.path}/large-output')..createSync();
      for (var index = 0; index < pageCount; index++) {
        File(
          '${source.path}/${index.toString().padLeft(4, '0')}.jpg',
        ).writeAsStringSync('page $index');
      }
      var listings = 0;
      var listedEntries = 0;
      var sourceReads = 0;
      final parent = Zone.current;
      File countedFile(File file) => path.isWithin(source.path, file.path)
          ? _CountedSourceFile(file, () => sourceReads++)
          : file;
      final progress = <({ComicCopyStage stage, int current, int total})>[];
      await IOOverrides.runZoned(
        () async {
          final pending = await ComicCopyRecord.prepare(
            Directory(destination.path),
            source: Directory(source.path),
          );
          await pending.resume(
            onProgress: (stage, current, total) =>
                progress.add((stage: stage, current: current, total: total)),
          );
        },
        createDirectory: (value) =>
            _CountedDirectory(parent.run(() => Directory(value)), (entries) {
              listings++;
              listedEntries += entries.length;
              return entries
                  .map((entry) => entry is File ? countedFile(entry) : entry)
                  .toList();
            }),
        createFile: (value) => countedFile(parent.run(() => File(value))),
      );
      expect(listings, lessThanOrEqualTo(8));
      expect(listedEntries, lessThanOrEqualTo(pageCount * 8));
      expect(sourceReads, pageCount * 2);
      await ComicCopyRecord.read(destination).verifyComplete();
      expect(source.listSync(), hasLength(pageCount));
      for (final stage in [ComicCopyStage.copying, ComicCopyStage.verifying]) {
        final updates = progress.where((update) => update.stage == stage);
        expect(updates.first.current, 0);
        expect(updates.last.current, pageCount);
        expect(updates.every((update) => update.total == pageCount), isTrue);
      }
    },
  );

  for (final conflict in ['directory', 'case alias']) {
    test(
      'resume preserves a staging $conflict introduced after checking',
      () async {
        final pending = await resumable();
        final name = conflict == 'case alias'
            ? ComicCopyRecord.stagingName.toUpperCase()
            : ComicCopyRecord.stagingName;
        final stagingPath = '${pending.directory.path}/$name';
        await expectLater(
          pending.resume(
            onProgress: (stage, current, total) {
              if (stage != ComicCopyStage.copying || current != 0) return;
              if (conflict == 'directory') {
                Directory(stagingPath).createSync();
              } else {
                File(stagingPath).writeAsStringSync('keep unrelated file');
              }
            },
          ),
          throwsA(anyOf(isA<StateError>(), isA<FileSystemException>())),
        );
        expect(pending.hasCompletion, isFalse);
        if (conflict == 'directory') {
          expect(Directory(stagingPath).existsSync(), isTrue);
        } else {
          expect(File(stagingPath).readAsStringSync(), 'keep unrelated file');
        }
      },
    );
  }

  test('resume checks source bytes for pages already copied', () async {
    final pending = await resumable();
    File('${pending.directory.path}/1.jpg').writeAsStringSync('first page');
    File('${root.path}/source/1.jpg').writeAsStringSync('other page');
    await expectLater(pending.resume(), throwsStateError);
    expect(pending.hasCompletion, isFalse);
    expect(
      File('${pending.directory.path}/1.jpg').readAsStringSync(),
      'first page',
    );
    expect(
      File('${pending.directory.path}/chapter/2.jpg').existsSync(),
      isFalse,
    );
  });

  for (final missing in [false, true]) {
    test(
      'resume rejects source tree changes before copying; missing=$missing',
      () async {
        final pending = await resumable();
        if (missing) {
          File('${root.path}/source/1.jpg').deleteSync();
        } else {
          File('${root.path}/source/extra.jpg').writeAsStringSync('extra page');
        }
        await expectLater(pending.resume(), throwsStateError);
        expect(pending.hasCompletion, isFalse);
        expect(File('${pending.directory.path}/1.jpg').existsSync(), isFalse);
      },
    );
  }

  test(
    'resumes missing files and a torn staging write after reopening',
    () async {
      final pending = await resumable();
      final directory = pending.directory;
      File('${directory.path}/1.jpg').writeAsStringSync('first page');
      File(
        '${directory.path}/${ComicCopyRecord.stagingName}',
      ).writeAsStringSync('sec');
      await ComicCopyRecord.read(directory).resume();
      await ComicCopyRecord.read(directory).verifyComplete();
      expect(
        File('${directory.path}/chapter/2.jpg').readAsStringSync(),
        'second page',
      );
      expect(Directory('${directory.path}/empty').existsSync(), isTrue);
      expect(
        File('${directory.path}/${ComicCopyRecord.stagingName}').existsSync(),
        isFalse,
      );
    },
  );

  for (final edit in ['source', 'output', 'extra']) {
    test(
      'resume preserves conflicts and never certifies changed $edit',
      () async {
        final pending = await resumable();
        final location = edit == 'source'
            ? '${root.path}/source'
            : pending.directory.path;
        final file = File(
          '$location/${edit == 'extra' ? 'extra.jpg' : '1.jpg'}',
        );
        file.writeAsStringSync('changed');
        await expectLater(
          ComicCopyRecord.read(pending.directory).resume,
          throwsStateError,
        );
        expect(file.readAsStringSync(), 'changed');
        expect(pending.hasCompletion, isFalse);
        expect(
          File('${pending.directory.path}/chapter/2.jpg').existsSync(),
          isFalse,
        );
      },
    );
  }

  test('version 2 cannot complete a partial payload', () async {
    final pending = await resumable();
    File('${pending.directory.path}/1.jpg').writeAsStringSync('first page');
    await expectLater(pending.complete, throwsStateError);
    expect(pending.hasCompletion, isFalse);
  });

  for (final key in [
    '["..","escape.jpg"]',
    '["chapter/escape.jpg"]',
    '["chapter","2.jpg"]',
    '[".venera-copy-staging"]',
  ]) {
    test('manifest refuses unsafe or parentless path $key', () async {
      final pending = await resumable();
      final file = File(
        '${pending.directory.path}/${ComicCopyRecord.intentName}',
      );
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      value['tree'] = {key: 'a' * 64};
      file.writeAsStringSync(jsonEncode(value));
      expect(
        () => ComicCopyRecord.read(pending.directory),
        throwsFormatException,
      );
      expect(file.existsSync(), isTrue);
    });
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

class _CountedDirectory extends Fake implements Directory {
  _CountedDirectory(this.actual, this.onList);
  final Directory actual;
  final List<FileSystemEntity> Function(List<FileSystemEntity>) onList;
  @override
  String get path => actual.path;
  @override
  String resolveSymbolicLinksSync() => actual.resolveSymbolicLinksSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => onList(actual.listSync(recursive: recursive, followLinks: followLinks));
  @override
  void createSync({bool recursive = false}) =>
      actual.createSync(recursive: recursive);
  @override
  bool existsSync() => actual.existsSync();
}

class _CountedSourceFile extends Fake implements File {
  _CountedSourceFile(this.actual, this.onRead);
  final File actual;
  final void Function() onRead;
  @override
  String get path => actual.path;
  @override
  int lengthSync() => actual.lengthSync();
  @override
  Uint8List readAsBytesSync() {
    onRead();
    return actual.readAsBytesSync();
  }
}
