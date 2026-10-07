import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  test(
    'provider allocation avoids observed collisions without createTemp',
    () async {
      final root = Directory.systemTemp.createTempSync('copy-provider-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory('${root.path}/source')..createSync();
      File('${source.path}/page.jpg').writeAsStringSync('new pages');
      final target = Directory('${root.path}/target')..createSync();
      final parent = Zone.current;
      Directory? occupied;
      final result = await IOOverrides.runZoned(
        () => ComicDirectoryCopier().copy([
          source.path,
        ], _ProviderDirectory(target)),
        createDirectory: (value) {
          final actual = parent.run(() => Directory(value));
          if (!path.isWithin(target.path, value)) return actual;
          if (occupied == null) {
            occupied = actual..createSync();
            File('${actual.path}/original.txt').writeAsStringSync('original');
          }
          return _ProviderDirectory(actual);
        },
      );
      expect(result.failures, isEmpty);
      expect(result.copies[source.path], isNot(occupied!.path));
      expect(
        File('${occupied!.path}/original.txt').readAsStringSync(),
        'original',
      );
      expect(
        File('${result.copies[source.path]}/page.jpg').readAsStringSync(),
        'new pages',
      );
    },
  );

  test(
    'provider silent-create failure does not claim output ownership',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'copy-provider-failure-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory('${root.path}/source')..createSync();
      File('${source.path}/page.jpg').writeAsStringSync('keep');
      final target = Directory('${root.path}/target')..createSync();
      final parent = Zone.current;
      final result = await IOOverrides.runZoned(
        () => ComicDirectoryCopier().copy([
          source.path,
        ], _ProviderDirectory(target)),
        createDirectory: (value) {
          final actual = parent.run(() => Directory(value));
          return path.isWithin(target.path, value)
              ? _ProviderDirectory(actual, createSucceeds: false)
              : actual;
        },
      );
      expect(result.copies, isEmpty);
      expect(
        result.failures[source.path]!.cause.toString(),
        contains('was not created'),
      );
      expect(result.failures[source.path]!.outputPath, isNull);
      expect(target.listSync(), isEmpty);
      expect(File('${source.path}/page.jpg').readAsStringSync(), 'keep');
    },
  );

  test('duplicate source entries produce only one owned output', () async {
    final root = Directory.systemTemp.createTempSync('copy-duplicate-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory('${root.path}/source')..createSync();
    File('${source.path}/page.jpg').writeAsStringSync('page');
    final target = Directory('${root.path}/target')..createSync();
    final result = await copyComicDirectories(
      ComicDirectoryCopyRequest(
        directories: [source.path, source.path],
        destination: target.path,
      ),
    );
    expect(result.copies, hasLength(1));
    expect(target.listSync(), hasLength(1));
    expect(result.failures, isEmpty);
  });

  for (final existingFile in [false, true]) {
    test(
      'occupied empty directory or file is preserved; file=$existingFile',
      () async {
        final root = Directory.systemTemp.createTempSync('copy-empty-');
        addTearDown(() => root.deleteSync(recursive: true));
        final source = Directory('${root.path}/source/Book')
          ..createSync(recursive: true);
        File('${source.path}/page.jpg').writeAsStringSync('page');
        final target = Directory('${root.path}/target')..createSync();
        final occupied = '${target.path}/Book';
        if (existingFile) {
          File(occupied).writeAsStringSync('original file');
        } else {
          Directory(occupied).createSync();
        }
        final result = await copyComicDirectories(
          ComicDirectoryCopyRequest(
            directories: [source.path],
            destination: target.path,
          ),
        );
        expect(result.failures, isEmpty);
        expect(result.copies[source.path], isNot(occupied));
        if (existingFile) {
          expect(File(occupied).readAsStringSync(), 'original file');
        } else {
          expect(Directory(occupied).existsSync(), isTrue);
          expect(Directory(occupied).listSync(), isEmpty);
        }
      },
    );
  }

  test(
    'two real isolates reserve distinct copies of the same source',
    () async {
      final root = Directory.systemTemp.createTempSync('copy-parallel-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory('${root.path}/source')..createSync();
      File('${source.path}/page.jpg').writeAsStringSync('page');
      final target = Directory('${root.path}/target')..createSync();
      final request = ComicDirectoryCopyRequest(
        directories: [source.path],
        destination: target.path,
      );
      final results = await Future.wait([
        compute(copyComicDirectories, request),
        compute(copyComicDirectories, request),
      ]);
      expect(results.every((result) => result.failures.isEmpty), isTrue);
      expect(
        results.map((result) => result.copies[source.path]).toSet(),
        hasLength(2),
      );
      for (final result in results) {
        expect(
          File('${result.copies[source.path]}/page.jpg').readAsStringSync(),
          'page',
        );
      }
    },
  );

  for (final nested in [false, true]) {
    test('rejects copying into the source; nested=$nested', () async {
      final source = Directory.systemTemp.createTempSync('copy-recursive-');
      addTearDown(() => source.deleteSync(recursive: true));
      File('${source.path}/page.jpg').writeAsStringSync('keep');
      final target = nested
          ? (Directory('${source.path}/target')..createSync())
          : source;
      final result = await copyComicDirectories(
        ComicDirectoryCopyRequest(
          directories: [source.path],
          destination: target.path,
        ),
      );
      expect(result.copies, isEmpty);
      expect(result.failures[source.path]!.cause, isA<FileSystemException>());
      expect(result.failures[source.path]!.outputPath, isNull);
      expect(File('${source.path}/page.jpg').readAsStringSync(), 'keep');
      if (nested) expect(target.listSync(), isEmpty);
    });
  }

  test(
    'cleanup failure preserves copy diagnostics and later successful results',
    () async {
      final root = Directory.systemTemp.createTempSync('copy-cleanup-');
      addTearDown(() => root.deleteSync(recursive: true));
      final bad = Directory('${root.path}/bad')..createSync();
      File('${bad.path}/page.jpg').createSync();
      final good = Directory('${root.path}/good')..createSync();
      File('${good.path}/page.jpg').writeAsStringSync('good');
      final target = Directory('${root.path}/target')..createSync();
      final cleanup = StateError('output removal failed');
      final cleanupStack = StackTrace.current;
      final copier = ComicDirectoryCopier(
        reserveDirectory: (root, name) {
          final output = root.createTempSync('${name}_');
          return name == 'bad'
              ? _FailingDelete(output, cleanup, cleanupStack)
              : output;
        },
      );
      final result = await copier.copy([bad.path, good.path], target);
      final failure = result.failures[bad.path]!;
      expect(failure.cause, isA<FileSystemException>());
      expect(failure.cause.toString(), contains('Incomplete file read'));
      expect(failure.stackTrace, isNotNull);
      expect(failure.cleanupError, same(cleanup));
      expect(failure.cleanupStack, same(cleanupStack));
      expect(Directory(failure.outputPath!).existsSync(), isTrue);
      expect(result.copies.keys, [good.path]);
      expect(
        File('${result.copies[good.path]}/page.jpg').readAsStringSync(),
        'good',
      );
      expect(bad.existsSync(), isTrue);
    },
  );

  test(
    'allocation failure does not delete input and later copies continue',
    () async {
      final root = Directory.systemTemp.createTempSync('copy-allocation-');
      addTearDown(() => root.deleteSync(recursive: true));
      final bad = Directory('${root.path}/bad')..createSync();
      File('${bad.path}/page.jpg').writeAsStringSync('keep');
      final good = Directory('${root.path}/good')..createSync();
      File('${good.path}/page.jpg').writeAsStringSync('good');
      final target = Directory('${root.path}/target')..createSync();
      final original = StateError('reservation failed');
      final copier = ComicDirectoryCopier(
        reserveDirectory: (root, name) {
          if (name == 'bad') throw original;
          return root.createTempSync('${name}_');
        },
      );
      final result = await copier.copy([bad.path, good.path], target);
      expect(result.failures[bad.path]!.cause, same(original));
      expect(result.failures[bad.path]!.outputPath, isNull);
      expect(result.failures[bad.path]!.cleanupError, isNull);
      expect(File('${bad.path}/page.jpg').readAsStringSync(), 'keep');
      expect(result.copies.keys, [good.path]);
    },
  );

  test('successful copy never moves an occupied destination', () async {
    final root = Directory.systemTemp.createTempSync('copy-occupied-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory('${root.path}/input/Book')
      ..createSync(recursive: true);
    File('${source.path}/page.jpg').writeAsStringSync('new comic');
    final occupied = Directory('${root.path}/library/Book')
      ..createSync(recursive: true);
    File('${occupied.path}/page.jpg').writeAsStringSync('original comic');
    final result = await copyComicDirectories(
      ComicDirectoryCopyRequest(
        directories: [source.path],
        destination: occupied.parent.path,
      ),
    );
    expect(
      File('${occupied.path}/page.jpg').readAsStringSync(),
      'original comic',
    );
    expect(result.copies[source.path], isNot(occupied.path));
    expect(
      File('${result.copies[source.path]}/page.jpg').readAsStringSync(),
      'new comic',
    );
    expect(Directory('${occupied.path}_old').existsSync(), isFalse);
  });

  test('equal source basenames keep different copied content', () async {
    final root = Directory.systemTemp.createTempSync('copy-basename-');
    addTearDown(() => root.deleteSync(recursive: true));
    final first = Directory('${root.path}/first/Book')
      ..createSync(recursive: true);
    final second = Directory('${root.path}/second/Book')
      ..createSync(recursive: true);
    File('${first.path}/page.jpg').writeAsStringSync('first');
    File('${second.path}/page.jpg').writeAsStringSync('second');
    final target = Directory('${root.path}/library')..createSync();
    final result = await copyComicDirectories(
      ComicDirectoryCopyRequest(
        directories: [first.path, second.path],
        destination: target.path,
      ),
    );
    expect(result.copies[first.path], isNot(result.copies[second.path]));
    expect(
      File('${result.copies[first.path]}/page.jpg').readAsStringSync(),
      'first',
    );
    expect(
      File('${result.copies[second.path]}/page.jpg').readAsStringSync(),
      'second',
    );
  });

  test(
    'a failed import leaves existing directory untouched and later comics still copy',
    () async {
      final root = Directory.systemTemp.createTempSync('comic-copy-');
      final muted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() {
        Log.isMuted = muted;
        root.deleteSync(recursive: true);
      });
      final bad = Directory('${root.path}/input/Bad/chapter')
        ..createSync(recursive: true);
      File('${bad.path}/page.jpg').createSync();
      final good = Directory('${root.path}/input/Good')..createSync();
      File('${good.path}/page.jpg').writeAsBytesSync([1, 2, 3]);
      final existing = Directory('${root.path}/output/Bad')
        ..createSync(recursive: true);
      File('${existing.path}/original.txt').writeAsStringSync('keep');
      final result = await copyComicDirectories(
        ComicDirectoryCopyRequest(
          directories: [bad.parent.path, good.path],
          destination: existing.parent.path,
        ),
      );
      expect(result.copies.keys, [good.path]);
      expect(File('${existing.path}/original.txt').readAsStringSync(), 'keep');
      expect(Directory('${existing.path}/chapter').existsSync(), isFalse);
      expect(
        Directory('${existing.parent.path}/Bad_old').existsSync(),
        isFalse,
      );
      expect(File('${result.copies[good.path]}/page.jpg').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
    },
  );
}

class _FailingDelete extends Fake implements Directory {
  _FailingDelete(this.actual, this.error, this.stack);
  final Directory actual;
  final Object error;
  final StackTrace stack;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  void deleteSync({bool recursive = false}) =>
      Error.throwWithStackTrace(error, stack);
}

// Exercises the SAF branch against real temporary files. Unsupported APIs
// retain Fake's throwing implementation; this does not emulate a real provider.
class _ProviderDirectory extends Fake implements AndroidDirectory {
  _ProviderDirectory(this.actual, {this.createSucceeds = true});
  final Directory actual;
  final bool createSucceeds;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => actual.listSync(recursive: recursive, followLinks: followLinks);
  @override
  void createSync({bool recursive = false}) {
    if (createSucceeds) actual.createSync(recursive: recursive);
  }

  @override
  void deleteSync({bool recursive = false}) =>
      actual.deleteSync(recursive: recursive);
}
