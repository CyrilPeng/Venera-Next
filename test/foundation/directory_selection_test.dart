import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/directory_selection.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  late Directory root;
  late Directory cache;
  late Directory source;
  setUp(() {
    root = Directory.systemTemp.createTempSync('directory-selection-');
    cache = Directory(p.join(root.path, 'cache'))..createSync();
    source = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(source.path, 'book.cbz')).writeAsStringSync('original');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'borrowed directories under cache and similar prefixes remain untouched',
    () async {
      for (final directory in [
        cache,
        Directory('${cache.path}-other')..createSync(),
      ]) {
        final file = File(p.join(directory.path, 'keep'))
          ..writeAsStringSync('keep');
        final selection = DirectorySelection(directory);
        await selection.withDirectory(
          (value) async => expect(value.path, directory.path),
        );
        await selection.dispose();
        await selection.dispose();
        expect(file.readAsStringSync(), 'keep');
      }
    },
  );

  test(
    'concurrent consumers share one copy and separate selections cannot overwrite it',
    () async {
      var copies = 0;
      DirectorySelection selected() => DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: (source, destination) async {
          copies++;
          await copyDirectory(source, destination);
        },
      );
      final first = selected();
      final second = selected();
      final paths = await Future.wait([
        first.withDirectory((directory) async => directory.path),
        first.withDirectory((directory) async => directory.path),
        second.withDirectory((directory) async => directory.path),
      ]);
      expect(copies, 2);
      expect(paths[0], paths[1]);
      expect(paths[0], isNot(paths[2]));
      await first.dispose();
      expect(File(p.join(paths[2], 'book.cbz')).readAsStringSync(), 'original');
      await second.dispose();
      expect(cache.listSync(), isEmpty);
      expect(
        File(p.join(source.path, 'book.cbz')).readAsStringSync(),
        'original',
      );
    },
  );

  test(
    'close before a consumer starts creates no temporary directory',
    () async {
      var copies = 0;
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: (_, _) async {
          copies++;
        },
      );
      final use = expectLater(
        selection.withDirectory((_) async {}),
        throwsStateError,
      );
      await selection.dispose();
      await use;
      expect(copies, 0);
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'close waits a running copy and never delivers its late directory',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: (_, directory) async {
          entered.complete();
          await finish.future;
          await File(p.join(directory.path, 'partial')).writeAsString('done');
        },
      );
      var delivered = false;
      final use = expectLater(
        selection.withDirectory((_) async {
          delivered = true;
        }),
        throwsStateError,
      );
      await entered.future;
      var closed = false;
      final closing = selection.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      finish.complete();
      await Future.wait([use, closing]);
      expect(delivered, isFalse);
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'close keeps native access until a consumer and its retain callback finish',
    () async {
      final retainEntered = Completer<void>();
      final retainGate = Completer<void>();
      final consumeGate = Completer<void>();
      var releases = 0;
      var retains = 0;
      final selection = DirectorySelection(
        source,
        releaseAccess: () async {
          releases++;
        },
        retainAccess: () async {
          retains++;
          retainEntered.complete();
          await retainGate.future;
        },
      );
      final use = selection.withDirectory((_) async => consumeGate.future);
      final retained = selection.retainAccessForSession();
      expect(selection.retainAccessForSession(), same(retained));
      await retainEntered.future;
      final closing = selection.dispose();
      retainGate.complete();
      await retained;
      await pumpEventQueue();
      expect(releases, 0);
      consumeGate.complete();
      await Future.wait([use, closing]);
      expect(retains, 1);
      expect(releases, 1);
    },
  );

  test(
    'native release failure preserves original operation and can retry only release',
    () async {
      var attempts = 0;
      var operations = 0;
      final cause = StateError('scan failed');
      final cleanup = StateError('release failed');
      final selection = DirectorySelection(
        source,
        releaseAccess: () async {
          if (++attempts == 1) throw cleanup;
        },
      );
      await expectLater(
        withSelectedDirectory<void>(
          selection,
          (selected) => selected.withDirectory((_) async {
            operations++;
            throw cause;
          }),
        ),
        throwsA(
          isA<DirectorySelectionCleanupFailure>()
              .having((e) => e.operationError, 'operation', same(cause))
              .having((e) => e.cleanupError, 'cleanup', same(cleanup))
              .having((e) => e.selection, 'selection', same(selection)),
        ),
      );
      await selection.dispose();
      expect(attempts, 2);
      expect(operations, 1);
      expect(source.existsSync(), isTrue);
    },
  );

  test(
    'failed copy is cleaned without deleting the source or running a consumer',
    () async {
      final error = StateError('copy failed');
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: (_, directory) async {
          await File(
            p.join(directory.path, 'partial'),
          ).writeAsString('partial');
          throw error;
        },
      );
      await expectLater(
        withSelectedDirectory(
          selection,
          (selected) =>
              selected.withDirectory((_) async => fail('unexpected delivery')),
        ),
        throwsA(same(error)),
      );
      expect(cache.listSync(), isEmpty);
      expect(source.existsSync(), isTrue);
    },
  );

  test(
    'unknown sibling and modified receipt retain copies until repaired',
    () async {
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: copyDirectory,
      );
      final path = await selection.withDirectory(
        (directory) async => directory.path,
      );
      final owner = Directory(path).parent;
      final sibling = File(p.join(owner.path, 'unknown'))
        ..writeAsStringSync('keep');
      await expectLater(
        selection.dispose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(sibling.readAsStringSync(), 'keep');
      sibling.deleteSync();
      final receipt = File(p.join(owner.path, '.selection-owner'));
      final token = receipt.readAsStringSync();
      receipt.writeAsStringSync('changed');
      await expectLater(
        selection.dispose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(path, 'book.cbz')).existsSync(), isTrue);
      receipt.writeAsStringSync(token);
      await selection.dispose();
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'a root contents link cannot redirect cleanup outside its owner',
    () async {
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: copyDirectory,
      );
      final path = await selection.withDirectory(
        (directory) async => directory.path,
      );
      Directory(path).deleteSync(recursive: true);
      final link = Link(path)..createSync(source.path);
      try {
        await expectLater(
          selection.dispose(),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          File(p.join(source.path, 'book.cbz')).readAsStringSync(),
          'original',
        );
      } finally {
        link.deleteSync();
      }
      await selection.dispose();
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'descendant links are deleted without touching their borrowed targets',
    () async {
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: copyDirectory,
      );
      final path = await selection.withDirectory(
        (directory) async => directory.path,
      );
      Link(p.join(path, 'linked-source')).createSync(source.path);
      await selection.dispose();
      expect(
        File(p.join(source.path, 'book.cbz')).readAsStringSync(),
        'original',
      );
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'temporary directories cannot be retained as library references',
    () async {
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: copyDirectory,
      );
      await expectLater(selection.retainAccessForSession(), throwsStateError);
      await selection.dispose();
      expect(cache.listSync(), isEmpty);
    },
  );
  test(
    'last directory deletion can retry after this owner removed its receipt',
    () async {
      final directory = _FailOnceCache(cache);
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: directory,
        copy: copyDirectory,
      );
      await selection.withDirectory((_) async {});
      await expectLater(
        selection.dispose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(cache.listSync(), hasLength(1));
      expect((cache.listSync().single as Directory).listSync(), isEmpty);
      await selection.dispose();
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'missing receipt after external removal is not inferred from an empty root',
    () async {
      final selection = DirectorySelection.copy(
        source: source,
        cacheDirectory: cache,
        copy: copyDirectory,
      );
      final path = await selection.withDirectory(
        (directory) async => directory.path,
      );
      final owner = Directory(path).parent;
      final receipt = File(p.join(owner.path, '.selection-owner'));
      final token = receipt.readAsStringSync();
      Directory(path).deleteSync(recursive: true);
      receipt.deleteSync();
      await expectLater(
        selection.dispose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(owner.existsSync(), isTrue);
      receipt.writeAsStringSync(token);
      await selection.dispose();
    },
  );
}

class _FailOnceCache extends Fake implements Directory {
  _FailOnceCache(this.directory);
  final Directory directory;
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _FailOnceRoot(await directory.createTemp(prefix));
}

class _FailOnceRoot extends Fake implements Directory {
  _FailOnceRoot(this.directory);
  final Directory directory;
  bool failed = false;
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
    if (!failed) {
      failed = true;
      throw const FileSystemException('delete failed');
    }
    await directory.delete(recursive: recursive);
    return this;
  }
}
