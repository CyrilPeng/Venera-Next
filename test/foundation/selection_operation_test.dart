import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/directory_selection.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/selection_operation.dart';

class _File extends FileSelection {
  _File({this.prepareGate, this.release}) : super('selected.cbz');
  final Future<File>? prepareGate;
  final Future<void> Function()? release;
  int prepares = 0;
  int releases = 0;
  @override
  Future<File> prepare() {
    prepares++;
    return prepareGate ?? Future.value(File(identifier));
  }

  @override
  Future<void> dispose() async {
    releases++;
    await release?.call();
  }
}

void main() {
  group('owned working copy', () {
    late Directory root;
    late Directory cache;
    late File source;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('selection-copy-test-');
      cache = await Directory(p.join(root.path, 'cache')).create();
      source = await File(
        p.join(root.path, 'original.venera'),
      ).writeAsBytes([1, 2, 3]);
    });
    tearDown(() => root.delete(recursive: true));

    test(
      'same-named private copies preserve bytes and borrowed source',
      () async {
        final operation = SelectionOperation();
        final paths = <String>[];
        await operation.run((owner) async {
          final selection = await owner.pickFile(
            () async => FileSelection(source.path),
          );
          for (var i = 0; i < 2; i++) {
            await owner.useFileCopy(
              selection!,
              cacheDirectory: cache,
              consume: (file) async {
                paths.add(file.path);
                expect(await file.readAsBytes(), [1, 2, 3]);
                expect(p.basename(file.path), 'original.venera');
                await file.writeAsBytes([4]);
              },
            );
          }
          expect(cache.listSync(), hasLength(2));
        });
        expect(paths.toSet(), hasLength(2));
        expect(cache.listSync(), isEmpty);
        expect(await source.readAsBytes(), [1, 2, 3]);
      },
    );

    test('document names stay inside the owned contents directory', () async {
      final operation = SelectionOperation();
      final selected = _NamedSelection(source, r'../../..\outside.venera');
      await operation.run((owner) async {
        await owner.pickFile(() async => selected);
        await owner.useFileCopy(
          selected,
          cacheDirectory: cache,
          consume: (file) async {
            expect(p.basename(file.path), 'outside.venera');
            expect(p.isWithin(cache.path, file.path), isTrue);
            expect(p.basename(file.parent.path), 'contents');
            expect(await file.readAsBytes(), [1, 2, 3]);
          },
        );
      });
      expect(cache.listSync(), isEmpty);
      expect(source.existsSync(), isTrue);
    });

    test('close waits for import and refresh before deleting copy', () async {
      final operation = SelectionOperation();
      final entered = Completer<File>();
      final finish = Completer<void>();
      var imports = 0;
      var refreshes = 0;
      final result = operation.run((owner) async {
        final selection = await owner.pickFile(
          () async => FileSelection(source.path),
        );
        await owner.useFileCopy(
          selection!,
          cacheDirectory: cache,
          consume: (file) async {
            try {
              imports++;
              entered.complete(file);
              await finish.future;
            } finally {
              refreshes++;
            }
          },
        );
      });
      final copy = await entered.future;
      var closed = false;
      final closing = operation.closeAndWait().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(copy.existsSync(), isTrue);
      finish.complete();
      await result;
      await closing;
      await operation.closeAndWait();
      expect(imports, 1);
      expect(refreshes, 1);
      expect(copy.existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
    });

    for (final failCopy in [false, true]) {
      test(
        'release retry preserves ${failCopy ? 'partial copy' : 'import'} failure without replay',
        () async {
          final operation = SelectionOperation();
          final cause = StateError('original failure');
          final causeStack = StackTrace.fromString('original operation stack');
          final cacheOwner = _FailingCache(cache);
          var copies = 0;
          var imports = 0;
          var refreshes = 0;
          final selected = _File(
            prepareGate: Future.value(
              _CopySource(source, (target) async {
                copies++;
                await File(target).writeAsBytes([1]);
                if (failCopy) Error.throwWithStackTrace(cause, causeStack);
                return source.copy(target);
              }),
            ),
          );
          final failureMatcher = isA<SelectionCleanupFailure>()
              .having((e) => e.operationError, 'cause', same(cause))
              .having((e) => e.operationStack, 'stack', same(causeStack))
              .having(
                (e) => e.failures.single,
                'copy cleanup',
                isA<DirectorySelectionCleanupFailure>(),
              );
          await expectLater(
            operation.run((owner) async {
              await owner.pickFile(() async => selected);
              await owner.useFileCopy(
                selected,
                cacheDirectory: cacheOwner,
                consume: (_) async {
                  try {
                    imports++;
                    Error.throwWithStackTrace(cause, causeStack);
                  } finally {
                    refreshes++;
                  }
                },
              );
            }),
            throwsA(failureMatcher),
          );
          expect(operation.hasPendingCleanup, isTrue);
          await expectLater(operation.closeAndWait(), throwsA(failureMatcher));
          cacheOwner.fails = false;
          await operation.closeAndWait();
          expect(copies, 1);
          expect(imports, failCopy ? 0 : 1);
          expect(refreshes, imports);
          expect(selected.releases, 1);
          expect(cache.listSync(), isEmpty);
          expect(await source.readAsBytes(), [1, 2, 3]);
        },
      );
    }

    test('cancel during copy drains preparation and refuses import', () async {
      final operation = SelectionOperation();
      final entered = Completer<void>();
      final finish = Completer<void>();
      final selected = _File(
        prepareGate: Future.value(
          _CopySource(source, (target) async {
            entered.complete();
            await finish.future;
            return source.copy(target);
          }),
        ),
      );
      final result = operation.run((owner) async {
        await owner.pickFile(() async => selected);
        await owner.useFileCopy(
          selected,
          cacheDirectory: cache,
          consume: (_) async => fail('late import'),
        );
      });
      final expected = expectLater(result, throwsA(isA<SelectionCancelled>()));
      await entered.future;
      var closed = false;
      final closing = operation.closeAndWait().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      finish.complete();
      await closing;
      await expected;
      expect(cache.listSync(), isEmpty);
      expect(source.existsSync(), isTrue);
    });
  });

  test('close before callback prevents picker creation', () async {
    final operation = SelectionOperation();
    final result = operation.run((_) async => fail('unstarted callback'));
    final expected = expectLater(result, throwsA(isA<SelectionCancelled>()));
    await operation.closeAndWait();
    await expected;
  });

  for (final directory in [false, true]) {
    test(
      'late selection is released before close, directory=$directory',
      () async {
        final operation = SelectionOperation();
        final entered = Completer<void>();
        final selected = Completer<void>();
        final released = Completer<void>();
        var releaseStarted = false;
        Future<void> release() async {
          releaseStarted = true;
          await released.future;
        }

        final file = _File(release: release);
        final dir = DirectorySelection(
          Directory.systemTemp,
          releaseAccess: release,
        );
        final result = operation.run((owner) async {
          if (directory) {
            await owner.pickDirectory(() async {
              entered.complete();
              await selected.future;
              return dir;
            });
          } else {
            await owner.pickFile(() async {
              entered.complete();
              await selected.future;
              return file;
            });
          }
          fail('Late selection was delivered');
        });
        final expected = expectLater(
          result,
          throwsA(isA<SelectionCancelled>()),
        );
        await entered.future;
        var closed = false;
        final closing = operation.closeAndWait().then((_) => closed = true);
        selected.complete();
        await Future<void>.delayed(Duration.zero);
        expect(releaseStarted, isTrue);
        expect(closed, isFalse);
        expect(file.prepares, 0);
        released.complete();
        await closing;
        await expected;
        expect(operation.hasPendingCleanup, isFalse);
      },
    );
  }

  test('close during native preparation waits and refuses consumer', () async {
    final gate = Completer<File>();
    final file = _File(prepareGate: gate.future);
    final operation = SelectionOperation();
    final entered = Completer<void>();
    final result = operation.run((owner) async {
      await owner.pickFile(() async => file);
      final work = owner.useFile(file, (_) async => fail('late consumer'));
      entered.complete();
      return work;
    });
    final expected = expectLater(result, throwsA(isA<SelectionCancelled>()));
    await entered.future;
    final closing = operation.closeAndWait();
    await Future<void>.delayed(Duration.zero);
    expect(file.releases, 0);
    gate.complete(File('selected.cbz'));
    await closing;
    await expected;
    expect(file.releases, 1);
  });

  test(
    'accepted consumer finishes before release without replay on close',
    () async {
      final file = _File();
      final operation = SelectionOperation();
      final entered = Completer<void>();
      final write = Completer<void>();
      var writes = 0;
      final result = operation.run((owner) async {
        await owner.pickFile(() async => file);
        return owner.useFile(file, (_) async {
          entered.complete();
          await write.future;
          writes++;
          return 'committed';
        });
      });
      await entered.future;
      final closing = operation.closeAndWait();
      expect(file.releases, 0);
      write.complete();
      expect(await result, 'committed');
      await closing;
      await operation.closeAndWait();
      expect(writes, 1);
      expect(file.releases, 1);
    },
  );

  test(
    'close between first and second picker never opens the second',
    () async {
      final file = _File();
      final operation = SelectionOperation();
      final result = operation.run((owner) async {
        await owner.pickFile(() async {
          owner.cancel();
          return file;
        });
        await owner.pickDirectory(() async => fail('second picker'));
      });
      await expectLater(result, throwsA(isA<SelectionCancelled>()));
      expect(file.releases, 1);
    },
  );

  test(
    'mixed cleanup failures preserve original cause and retry independently',
    () async {
      var fileFails = true;
      var dirFails = true;
      var directoryReleases = 0;
      final cause = StateError('database import failed');
      final stack = StackTrace.fromString('original import stack');
      final fileError = StateError('native file release');
      final dirError = StateError('directory release');
      final file = _File(
        release: () async {
          if (fileFails) throw fileError;
        },
      );
      final directory = DirectorySelection(
        Directory.systemTemp,
        releaseAccess: () async {
          directoryReleases++;
          if (dirFails) throw dirError;
        },
      );
      final operation = SelectionOperation();
      var runs = 0;
      SelectionCleanupFailure? first;
      try {
        await operation.run((owner) async {
          runs++;
          await owner.pickFile(() async => file);
          await owner.pickDirectory(() async => directory);
          Error.throwWithStackTrace(cause, stack);
        });
      } on SelectionCleanupFailure catch (failure) {
        first = failure;
      }
      expect(first.operationError, same(cause));
      expect(first.operationStack, same(stack));
      expect(first.failures, hasLength(2));
      expect(
        (first.failures.first as DirectorySelectionCleanupFailure).cleanupError,
        same(dirError),
      );
      expect(
        (first.failures.last as FileSelectionCleanupFailure).cleanupError,
        same(fileError),
      );
      dirFails = false;
      await expectLater(
        operation.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>()
              .having((f) => f.operationError, 'original cause', same(cause))
              .having((f) => f.failures.length, 'remaining', 1),
        ),
      );
      fileFails = false;
      await operation.closeAndWait();
      expect(runs, 1);
      expect(directoryReleases, 2);
      expect(file.releases, 3);
      expect(operation.hasPendingCleanup, isFalse);
    },
  );

  for (final accept in [false, true]) {
    test('batch transfer keeps ownership until accepted=$accept', () async {
      final files = [_File(), _File()];
      final operation = SelectionOperation();
      final result = operation.run((owner) async {
        final selected = await owner.pickFiles(() async => files);
        return owner.transferFiles(selected, () {
          owner.cancel(); // Receiver can synchronously reenter shutdown.
          if (!accept) throw StateError('queue rejected');
          return 'queued';
        });
      });
      if (accept) {
        expect(await result, 'queued');
      } else {
        await expectLater(result, throwsStateError);
      }
      await operation.closeAndWait();
      expect(files.map((f) => f.releases), [accept ? 0 : 1, accept ? 0 : 1]);
      if (accept) {
        for (final file in files) {
          await file.dispose();
        }
      }
    });
  }
}

class _CopySource extends Fake implements File {
  _CopySource(this.source, this.copyFile);
  final File source;
  final Future<File> Function(String) copyFile;
  @override
  Directory get parent => source.parent;
  @override
  Future<File> copy(String newPath) => copyFile(newPath);
}

class _NamedSelection extends FileSelection {
  _NamedSelection(this.source, String name)
    : super.androidDocument(uri: 'content://selected', name: name);
  final File source;
  @override
  Future<File> prepare() async => source;
}

class _FailingCache extends Fake implements Directory {
  _FailingCache(this.directory);
  final Directory directory;
  bool fails = true;
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _FailingRoot(await directory.createTemp(prefix), this);
}

class _FailingRoot extends Fake implements Directory {
  _FailingRoot(this.directory, this.owner);
  final Directory directory;
  final _FailingCache owner;
  @override
  String get path => directory.path;
  @override
  Future<String> resolveSymbolicLinks() => directory.resolveSymbolicLinks();
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => directory.list(recursive: recursive, followLinks: followLinks);
  @override
  Future<Directory> delete({bool recursive = false}) async {
    if (owner.fails) throw const FileSystemException('root release failed');
    await directory.delete(recursive: recursive);
    return this;
  }
}
