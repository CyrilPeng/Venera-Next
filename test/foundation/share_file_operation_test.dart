import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/share_file_operation.dart';

void main() {
  late Directory root;
  late Directory namespace;
  setUp(() {
    root = Directory.systemTemp.createTempSync('share-operation-');
    namespace = Directory(p.join(root.path, 'shares'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'creates missing namespace and retains dispatched source after acknowledgement',
    () async {
      File? delivered;
      final result = await withShareFileSource(
        data: Uint8List.fromList([1, 2, 3]),
        filename: '漫画 01.png',
        cacheDirectory: namespace,
        retainAfterDispatch: true,
        share: (source) async {
          delivered = source;
          expect(source.readAsBytesSync(), [1, 2, 3]);
          return 'acknowledged';
        },
      );
      expect(result, 'acknowledged');
      expect(delivered!.readAsBytesSync(), [1, 2, 3]);
      expect(p.basename(delivered!.path), '漫画 01.png');
      expect(p.isWithin(namespace.path, delivered!.path), isTrue);
      expect(namespace.listSync(), hasLength(1));
    },
  );

  test(
    'same-name concurrent shares own different sources and never delete neighbours',
    () async {
      namespace.createSync();
      final neighbour = File(p.join(namespace.path, 'same.png'))
        ..writeAsBytesSync([9]);
      final entered = Completer<void>();
      final sources = <File>[];
      final replies = <Completer<int>>[];
      Future<int> start(int value) => withShareFileSource(
        data: Uint8List.fromList([value]),
        filename: 'same.png',
        cacheDirectory: namespace,
        retainAfterDispatch: false,
        share: (source) {
          sources.add(source);
          final reply = Completer<int>();
          replies.add(reply);
          if (replies.length == 2) entered.complete();
          return reply.future;
        },
      );
      final first = start(1);
      final second = start(2);
      await entered.future;
      expect(sources[0].path, isNot(sources[1].path));
      expect(
        sources.map((file) => file.readAsBytesSync()),
        unorderedEquals([
          [1],
          [2],
        ]),
      );
      replies[0].complete(10);
      await _until(() => !sources[0].existsSync());
      expect(sources[1].existsSync(), isTrue);
      expect(neighbour.readAsBytesSync(), [9]);
      replies[1].complete(20);
      expect(await Future.wait([first, second]), unorderedEquals([10, 20]));
      expect(namespace.listSync().map((entry) => entry.path), [neighbour.path]);
    },
  );

  test('dispatch waits for complete asynchronous write and flush', () async {
    final writing = Completer<void>();
    final release = Completer<void>();
    File? staged;
    var dispatched = false;
    final overrides = _WriteOverrides(namespace.path, (
      file,
      bytes,
      mode,
      flush,
    ) async {
      expect(flush, isTrue);
      staged = file;
      await file.writeAsBytes(bytes.take(1).toList());
      writing.complete();
      await release.future;
      return file.writeAsBytes(bytes, mode: mode, flush: flush);
    });
    final sharing = IOOverrides.runWithIOOverrides(
      () => withShareFileSource(
        data: Uint8List.fromList([1, 2, 3]),
        filename: 'complete.bin',
        cacheDirectory: namespace,
        retainAfterDispatch: false,
        share: (source) async {
          dispatched = true;
          expect(source.readAsBytesSync(), [1, 2, 3]);
          return 7;
        },
      ),
      overrides,
    );
    await writing.future;
    expect(dispatched, isFalse);
    expect(staged!.readAsBytesSync(), [1]);
    release.complete();
    expect(await sharing, 7);
    expect(staged!.existsSync(), isFalse);
  });

  for (final retain in [false, true]) {
    test(
      'source remains available until original platform future returns; retain=$retain',
      () async {
        final entered = Completer<File>();
        final reply = Completer<bool>();
        var completed = false;
        final sharing =
            withShareFileSource(
              data: Uint8List.fromList([4]),
              filename: 'shared.bin',
              cacheDirectory: namespace,
              retainAfterDispatch: retain,
              share: (source) {
                entered.complete(source);
                return reply.future;
              },
            ).then((result) {
              completed = true;
              return result;
            });
        final source = await entered.future;
        await pumpEventQueue();
        expect(completed, isFalse);
        expect(source.readAsBytesSync(), [4]);
        reply.complete(false);
        expect(await sharing, isFalse);
        expect(source.existsSync(), retain);
        expect(namespace.existsSync(), isTrue);
      },
    );
  }

  for (final synchronous in [false, true]) {
    test(
      'retained source survives dispatch error with original stack; synchronous=$synchronous',
      () async {
        final error = StateError('dispatch may have handed off the path');
        final stack = StackTrace.fromString('original dispatch stack');
        File? delivered;
        final failure = await _capture(
          withShareFileSource<bool>(
            data: Uint8List.fromList([5]),
            filename: 'ambiguous.png',
            cacheDirectory: namespace,
            retainAfterDispatch: true,
            share: (source) {
              delivered = source;
              if (synchronous) Error.throwWithStackTrace(error, stack);
              return Future.error(error, stack);
            },
          ),
        );
        expect(failure.error, same(error));
        expect(failure.stack.toString(), stack.toString());
        expect(delivered!.readAsBytesSync(), [5]);
      },
    );
  }

  for (final stage in ['write', 'platform']) {
    for (final cleanupFails in [false, true]) {
      test(
        '$stage failure preserves original diagnostics; cleanupFails=$cleanupFails',
        () async {
          final operationError = StateError('$stage failed');
          final operationStack = StackTrace.fromString('original $stage stack');
          final cleanupError = StateError('cleanup failed');
          final cleanupStack = StackTrace.fromString('original cleanup stack');
          final directory = _Namespace(namespace, (owned) async {
            if (cleanupFails) {
              Error.throwWithStackTrace(cleanupError, cleanupStack);
            }
            return owned.delete(recursive: true);
          });
          var dispatched = false;
          final failure = await _capture(
            IOOverrides.runWithIOOverrides(
              () => withShareFileSource<bool>(
                data: Uint8List.fromList([6]),
                filename: 'failed.bin',
                cacheDirectory: directory,
                // Even a platform requiring retention must clean pre-dispatch
                // failures, whereas Android can clean after platform failure.
                retainAfterDispatch: stage == 'write',
                share: (_) {
                  dispatched = true;
                  return Future.error(operationError, operationStack);
                },
              ),
              _WriteOverrides(
                namespace.path,
                stage == 'write'
                    ? (_, _, _, _) =>
                          Future.error(operationError, operationStack)
                    : null,
              ),
            ),
          );
          expect(dispatched, stage == 'platform');
          expect(failure.stack.toString(), operationStack.toString());
          if (cleanupFails) {
            final combined = failure.error as ShareFileCleanupFailure;
            expect(combined.operationError, same(operationError));
            expect(
              combined.operationStackTrace.toString(),
              operationStack.toString(),
            );
            expect(combined.cleanupError, same(cleanupError));
            expect(
              combined.cleanupStackTrace.toString(),
              cleanupStack.toString(),
            );
          } else {
            expect(failure.error, same(operationError));
            expect(namespace.listSync(), isEmpty);
          }
        },
      );
    }
  }

  test(
    'a short write is rejected and cleaned before dispatch on a retaining platform',
    () async {
      var dispatched = false;
      final failure = await _capture(
        IOOverrides.runWithIOOverrides(
          () => withShareFileSource(
            data: Uint8List.fromList([1, 2, 3]),
            filename: 'short.bin',
            cacheDirectory: namespace,
            retainAfterDispatch: true,
            share: (_) async => dispatched = true,
          ),
          _WriteOverrides(
            namespace.path,
            (file, _, _, _) => file.writeAsBytes([1]),
          ),
        ),
      );
      expect(failure.error, isA<FileSystemException>());
      expect(dispatched, isFalse);
      expect(namespace.listSync(), isEmpty);
    },
  );

  test('cleanup is awaited and its sole failure retains its stack', () async {
    final cleaning = Completer<void>();
    final release = Completer<void>();
    final error = StateError('cleanup only');
    final stack = StackTrace.fromString('cleanup-only stack');
    final directory = _Namespace(namespace, (_) async {
      cleaning.complete();
      await release.future;
      Error.throwWithStackTrace(error, stack);
    });
    var completed = false;
    final sharing =
        _capture(
          withShareFileSource(
            data: Uint8List(0),
            filename: 'empty.dat',
            cacheDirectory: directory,
            retainAfterDispatch: false,
            share: (_) async => 'done',
          ),
        ).then((failure) {
          completed = true;
          return failure;
        });
    await cleaning.future;
    expect(completed, isFalse);
    release.complete();
    final failure = await sharing;
    expect(failure.error, same(error));
    expect(failure.stack.toString(), stack.toString());
  });

  test(
    'unsafe names become real portable leaf files while preserving Unicode and extensions',
    () async {
      final cases = <String, String>{
        r'..\漫画\页面.png': '页面.png',
        '/../../漫画.png': '漫画.png',
        r'C:\images\CON.png': '_CON.png',
        'aux.tar.gz': '_aux.tar.gz',
        'LPT¹.txt': '_LPT¹.txt',
        'COM9.png': '_COM9.png',
        'CONOUT\$.log': '_CONOUT\$.log',
        'a<b>:c"d|e?f*.png': 'a_b__c_d_e_f_.png',
        'control\u0000\u001f.png': 'control__.png',
        '漫画.png . ': '漫画.png',
        '... ': 'shared-file',
        '': 'shared-file',
        '.hidden': '.hidden',
        'e\u0301_日本語_🚀.png': 'e\u0301_日本語_🚀.png',
      };
      final neighbour = File(p.join(root.path, '漫画.png'))
        ..writeAsBytesSync([9]);
      for (final entry in cases.entries) {
        await withShareFileSource(
          data: Uint8List.fromList([1]),
          filename: entry.key,
          cacheDirectory: namespace,
          retainAfterDispatch: false,
          share: (source) async {
            expect(p.basename(source.path), entry.value, reason: entry.key);
            expect(p.dirname(p.dirname(source.path)), namespace.path);
            expect(source.readAsBytesSync(), [1]);
          },
        );
      }
      expect(neighbour.readAsBytesSync(), [9]);
      expect(namespace.listSync(), isEmpty);
    },
  );

  test(
    'long Unicode and ASCII titles keep legal extension and fit actual paths',
    () async {
      for (final title in ['漫画🚀' * 150, 'a' * 500]) {
        await withShareFileSource(
          data: Uint8List.fromList([1]),
          filename: '$title.png',
          cacheDirectory: namespace,
          retainAfterDispatch: false,
          share: (source) async {
            final name = p.basename(source.path);
            expect(name.endsWith('.png'), isTrue);
            expect(name.contains('\uFFFD'), isFalse);
            expect(utf8.encode(name).length, lessThanOrEqualTo(230));
            if (Platform.isWindows) {
              expect(source.absolute.path.length, lessThanOrEqualTo(259));
            }
            expect(source.readAsBytesSync(), [1]);
          },
        );
      }
      expect(namespace.listSync(), isEmpty);
    },
  );

  test(
    'an unrepresentable extension fails before dispatch without leaking its directory',
    () async {
      var dispatched = false;
      await expectLater(
        withShareFileSource(
          data: Uint8List.fromList([1]),
          filename: 'title.${'a' * 300}',
          cacheDirectory: namespace,
          retainAfterDispatch: true,
          share: (_) async => dispatched = true,
        ),
        throwsArgumentError,
      );
      expect(dispatched, isFalse);
      expect(namespace.listSync(), isEmpty);
    },
  );
}

Future<({Object error, StackTrace stack})> _capture(
  Future<dynamic> operation,
) async {
  try {
    await operation;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected operation to fail');
}

Future<void> _until(bool Function() complete) async {
  for (var i = 0; i < 200 && !complete(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(complete(), isTrue);
}

final class _WriteOverrides extends IOOverrides {
  _WriteOverrides(this.directory, this.write);
  final String directory;
  final Future<File> Function(File, List<int>, FileMode, bool)? write;
  @override
  File createFile(String path) {
    final raw = super.createFile(path);
    return write != null && p.isWithin(directory, path)
        ? _WrittenFile(raw, write!)
        : raw;
  }
}

class _WrittenFile implements File {
  _WrittenFile(this.raw, this.write);
  final File raw;
  final Future<File> Function(File, List<int>, FileMode, bool) write;
  @override
  String get path => raw.path;
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => write(raw, bytes, mode, flush);
  @override
  Future<int> length() => raw.length();
  @override
  Uint8List readAsBytesSync() => raw.readAsBytesSync();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Namespace implements Directory {
  _Namespace(this.raw, this.remove);
  final Directory raw;
  final Future<FileSystemEntity> Function(Directory) remove;
  @override
  Future<Directory> create({bool recursive = false}) async {
    await raw.create(recursive: recursive);
    return this;
  }

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _Owned(await raw.createTemp(prefix), remove);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Owned implements Directory {
  _Owned(this.raw, this.remove);
  final Directory raw;
  final Future<FileSystemEntity> Function(Directory) remove;
  @override
  String get path => raw.path;
  @override
  Directory get absolute => raw.absolute;
  @override
  Future<Directory> delete({bool recursive = false}) async {
    expect(recursive, isTrue);
    await remove(raw);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
