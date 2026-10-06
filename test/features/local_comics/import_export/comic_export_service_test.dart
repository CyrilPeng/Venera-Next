import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/directory_selection.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/comic_export_service.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/file_system.dart';

class _Comic extends Fake implements LocalComic {
  _Comic(this.title);
  @override
  final String title;
}

void main() {
  late Directory root;
  final single = [_Comic('Book')];
  final multiple = [_Comic('Book'), _Comic('book')];
  setUp(
    () => root = Directory.systemTemp.createTempSync('export-service-test-'),
  );
  tearDown(() => root.deleteSync(recursive: true));
  Future<File> export(LocalComic comic, String path) =>
      File(path).writeAsString(comic.title);
  Future<void> compress(String directory, String output) async {
    await File(output).writeAsString(
      Directory(
        directory,
      ).listSync().whereType<File>().map((f) => f.name).join(','),
    );
  }

  Future<void> run(
    List<LocalComic> comics, {
    ExportComicFunc? exporter,
    Future<void> Function(String, String)? zipper,
    Future<void> Function(File, String)? save,
    bool Function()? cancelled,
    SelectionOperation? owner,
  }) => (owner ?? SelectionOperation()).run(
    (operation) => exportLocalComics(
      comics,
      operation: operation,
      cachePath: root.path,
      extension: '.cbz',
      export: exporter ?? export,
      compress: zipper ?? compress,
      save: save ?? (file, name) async {},
      isCancelled: cancelled ?? () => false,
    ),
  );
  for (final stage in ['export', 'compress', 'save']) {
    test('retains $stage cause and staging for release-only retry', () async {
      final owner = SelectionOperation();
      final cause = StateError('$stage original');
      final stack = StackTrace.fromString('$stage stack');
      late File unknown;
      var exports = 0;
      var compressions = 0;
      var saves = 0;
      final operation = run(
        multiple,
        owner: owner,
        exporter: (comic, path) async {
          exports++;
          final file = await export(comic, path);
          final workspace = file.parent.parent.parent;
          unknown = File('${workspace.path}/unknown')
            ..writeAsStringSync('keep');
          if (stage == 'export') Error.throwWithStackTrace(cause, stack);
          return file;
        },
        zipper: (directory, output) async {
          compressions++;
          await compress(directory, output);
          if (stage == 'compress') Error.throwWithStackTrace(cause, stack);
        },
        save: (file, name) async {
          saves++;
          Error.throwWithStackTrace(cause, stack);
        },
      );
      SelectionCleanupFailure? initial;
      try {
        await operation;
        fail('Expected retained cleanup failure');
      } on SelectionCleanupFailure catch (error) {
        initial = error;
      }
      expect(initial.operationError, same(cause));
      expect(initial.operationStack, same(stack));
      expect(initial.failures.single, isA<DirectorySelectionCleanupFailure>());
      await expectLater(
        owner.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>()
              .having((e) => e.operationError, 'cause', same(cause))
              .having((e) => e.operationStack, 'stack', same(stack)),
        ),
      );
      expect(unknown.readAsStringSync(), 'keep');
      final counts = [exports, compressions, saves];
      unknown.deleteSync();
      await owner.closeAndWait();
      expect([exports, compressions, saves], counts);
      expect(owner.hasPendingCleanup, isFalse);
      expect(root.listSync(), isEmpty);
    });
  }

  test(
    'owner close joins active exporter and rejects remaining comics',
    () async {
      final owner = SelectionOperation();
      final entered = Completer<void>();
      final finish = Completer<void>();
      var exports = 0;
      final pending = run(
        multiple,
        owner: owner,
        exporter: (comic, path) async {
          exports++;
          final file = await export(comic, path);
          entered.complete();
          await finish.future;
          expect(file.existsSync(), isTrue);
          return file;
        },
        save: (_, _) async => fail('Cancelled export cannot save'),
      );
      final checked = expectLater(pending, throwsA(isA<SelectionCancelled>()));
      await entered.future;
      var closed = false;
      final closing = owner.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      finish.complete();
      await checked;
      await closing;
      expect(exports, 1);
      expect(root.listSync(), isEmpty);
    },
  );
  test(
    'single export owns file until save finishes and cleans afterwards',
    () async {
      final saving = Completer<void>();
      final started = Completer<void>();
      late File output;
      final pending = run(
        single,
        save: (file, name) async {
          output = file;
          expect(name, 'Book.cbz');
          expect(await file.readAsString(), 'Book');
          started.complete();
          await saving.future;
          expect(await file.exists(), isTrue);
        },
      );
      await started.future;
      expect(output.existsSync(), isTrue);
      saving.complete();
      await pending;
      expect(root.listSync(), isEmpty);
    },
  );
  test(
    'batch preserves colliding titles and archives outside the content directory',
    () async {
      await run(
        multiple,
        zipper: (directory, output) async {
          expect(File(output).parent.path, isNot(Directory(directory).path));
          expect(
            Directory(
              directory,
            ).listSync().whereType<File>().map((f) => f.name).toSet(),
            {'Book.cbz', 'book (2).cbz'},
          );
          await compress(directory, output);
        },
        save: (file, name) async {
          expect(name, 'comics_export.zip');
          expect(await file.readAsString(), contains('book (2).cbz'));
        },
      );
      expect(root.listSync(), isEmpty);
    },
  );
  for (final stage in ['export', 'compress', 'save']) {
    test('cleans staged files and preserves $stage failure', () async {
      final failure = StateError(stage);
      await expectLater(
        run(
          multiple,
          exporter: stage == 'export'
              ? (comic, path) async {
                  await export(comic, path);
                  throw failure;
                }
              : null,
          zipper: stage == 'compress'
              ? (directory, output) async {
                  await compress(directory, output);
                  throw failure;
                }
              : null,
          save: stage == 'save' ? (file, name) async => throw failure : null,
        ),
        throwsA(same(failure)),
      );
      expect(root.listSync(), isEmpty);
    });
  }
  for (final stage in ['export', 'compress']) {
    test('cancellation after $stage skips save and cleans workspace', () async {
      var cancelled = false;
      var exports = 0;
      await run(
        multiple,
        exporter: (comic, path) async {
          exports++;
          final file = await export(comic, path);
          if (stage == 'export') cancelled = true;
          return file;
        },
        zipper: (directory, output) async {
          await compress(directory, output);
          cancelled = true;
        },
        save: (file, name) async => fail('Cancelled work must not open save'),
        cancelled: () => cancelled,
      );
      expect(exports, stage == 'export' ? 1 : 2);
      expect(root.listSync(), isEmpty);
    });
  }
  for (final empty in [false, true]) {
    test(
      'empty or pre-cancelled work never creates staging: empty=$empty',
      () async {
        await run(
          empty ? [] : single,
          cancelled: () => !empty,
          exporter: (comic, path) async =>
              throw StateError('Unexpected export'),
        );
        expect(root.listSync(), isEmpty);
      },
    );
  }
  test(
    'concurrent exports own separate workspaces and preserve unrelated cache files',
    () async {
      final existing = Directory(FilePath.join(root.path, 'comics_export'))
        ..createSync();
      File(FilePath.join(existing.path, 'keep')).writeAsStringSync('keep');
      final gate = Completer<void>();
      final started = Completer<void>();
      late String firstPath;
      final first = run(
        single,
        exporter: (comic, path) async {
          firstPath = path;
          await export(comic, path);
          started.complete();
          await gate.future;
          expect(File(path).existsSync(), isTrue);
          return File(path);
        },
      );
      await started.future;
      await run(
        single,
        save: (file, name) async {
          expect(file.path, isNot(firstPath));
          expect(File(firstPath).existsSync(), isTrue);
        },
      );
      expect(File(firstPath).existsSync(), isTrue);
      gate.complete();
      await first;
      expect(root.listSync().map((e) => e.path), [existing.path]);
      expect(
        File(FilePath.join(existing.path, 'keep')).readAsStringSync(),
        'keep',
      );
    },
  );
}
