import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import '../../support/source_data_files.dart';

void main() {
  test(
    'storage preserves write and cleanup errors without replacing old data',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-storage-failures-',
      );
      addTearDown(() => root.delete(recursive: true));
      await const SourceDataStorage().write(
        root.path,
        'test',
        '{"token":"old"}',
      );
      final files = ControlledSourceDataFiles();
      final writeFailure = FileSystemException('write failure');
      final cleanupFailure = FileSystemException('cleanup failure');
      files.beforeWrite = (temporary, _) async {
        await temporary.writeAsString('partial');
        throw writeFailure;
      };
      files.beforeRemoveDirectory = (_) => throw cleanupFailure;
      await expectLater(
        SourceDataStorage(
          files: files,
        ).write(root.path, 'test', '{"token":"new"}'),
        throwsA(
          isA<SourceMutationFailure>()
              .having(
                (e) => e.state,
                'state',
                SourceMutationState.recoveryRequired,
              )
              .having((e) => e.failures.map((f) => f.error), 'both errors', [
                writeFailure,
                cleanupFailure,
              ])
              .having(
                (e) => Directory(e.recoveryPath!).existsSync(),
                'retained path',
                isTrue,
              ),
        ),
      );
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'old'},
      );
      expect(
        Directory(
          '${root.path}/comic_source',
        ).listSync().whereType<Directory>().single.listSync(),
        isEmpty,
      );
    },
  );

  test(
    'independent writes use distinct staging files and never delete another writer',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-storage-overlap-',
      );
      final files = ControlledSourceDataFiles();
      final first = Completer<void>();
      final second = Completer<void>();
      final release = Completer<void>();
      final stagedPaths = <String>[];
      files.beforeReplace = (temporary, _) async {
        stagedPaths.add(temporary.path);
        if (stagedPaths.length == 1) {
          first.complete();
          await release.future;
        } else {
          second.complete();
        }
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final storage = SourceDataStorage(files: files);
      final one = storage.write(root.path, 'test', '{"token":"one"}');
      await first.future;
      final two = storage.write(root.path, 'test', '{"token":"two"}');
      await second.future;
      await two;
      expect(stagedPaths.toSet(), hasLength(2));
      expect(File(stagedPaths.first).existsSync(), isTrue);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'two'},
      );
      release.complete();
      await one;
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'one'},
      );
      expect(
        Directory(
          '${root.path}/comic_source',
        ).listSync().whereType<Directory>(),
        isEmpty,
      );
      await root.delete(recursive: true);
    },
  );
}
