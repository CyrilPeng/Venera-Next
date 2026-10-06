import 'package:venera_next/foundation/platform_dialog_queue.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart' as interaction;
import 'package:venera_next/foundation/file_save_operation.dart' as saves;
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/foundation/directory_selection.dart';

const _selector = MethodChannel('plugins.flutter.io/file_selector');
const _mobile = MethodChannel('flutter_file_dialog');
const _iosDirectory = MethodChannel('venera/method_channel');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('file-save-test-');
    cache = Directory(p.join(root.path, 'cache'))..createSync();
    App.cachePath = cache.path;
  });
  tearDown(() async {
    for (final channel in [_selector, _mobile, _iosDirectory]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(interaction.IO.isSelectingFiles, isFalse);
    root.deleteSync(recursive: true);
  });

  test('startup IO override preserves entity types and save cleanup', () async {
    final caller = File(p.join(root.path, 'caller.bin'))..writeAsBytesSync([9]);
    messenger.setMockMethodCallHandler(
      _selector,
      (_) async => p.join(root.path, 'saved.bin'),
    );
    await interaction.overrideIO(() async {
      expect(
        await FileSystemEntity.type(root.path),
        FileSystemEntityType.directory,
      );
      expect(FileSystemEntity.typeSync(caller.path), FileSystemEntityType.file);
      final link = Link(p.join(root.path, 'borrowed-link'))
        ..createSync(caller.path);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await FileSystemEntity.type(link.path), FileSystemEntityType.file);
      expect(
        await FileSystemEntity.type('${root.path}/missing'),
        FileSystemEntityType.notFound,
      );
      await interaction.overrideIO(() async {
        expect(
          await _saveFile(
            data: Uint8List.fromList([1, 2]),
            filename: 'saved.bin',
          ),
          isTrue,
        );
      });
    });
    expect(cache.listSync(), isEmpty);
    expect(File(p.join(root.path, 'saved.bin')).readAsBytesSync(), [1, 2]);
    expect(caller.readAsBytesSync(), [9]);
  });

  test(
    'late desktop picker reply after close cannot write destination',
    () async {
      final reply = Completer<String?>();
      final entered = Completer<void>();
      final owner = SelectionOperation();
      messenger.setMockMethodCallHandler(_selector, (_) {
        entered.complete();
        return reply.future;
      });
      final saving = _saveFile(
        owner: owner,
        data: Uint8List.fromList([1]),
        filename: 'a.bin',
      );
      final checked = expectLater(saving, throwsA(isA<SelectionCancelled>()));
      await entered.future;
      var closed = false;
      final closing = owner.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(cache.listSync(), hasLength(1));
      final destination = File(p.join(root.path, 'late.bin'));
      reply.complete(destination.path);
      await checked;
      await closing;
      expect(destination.existsSync(), isFalse);
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'same-name saves retain separate bytes through real desktop copies',
    () async {
      final paths = <Completer<String?>>[];
      final entered = StreamController<void>();
      messenger.setMockMethodCallHandler(_selector, (call) {
        expect(call.method, 'getSavePath');
        expect(call.arguments['suggestedName'], '漫画 01.png');
        final path = Completer<String?>();
        paths.add(path);
        entered.add(null);
        return path.future;
      });
      final original = File(p.join(cache.path, '漫画 01.png'))
        ..writeAsBytesSync([9]);
      final first = _saveFile(
        data: Uint8List.fromList([1, 2]),
        filename: '漫画 01.png',
      );
      final second = _saveFile(
        data: Uint8List.fromList([3, 4]),
        filename: '漫画 01.png',
      );
      await entered.stream.take(2).drain<void>();
      final staging = cache.listSync().whereType<Directory>().toList();
      expect(staging, hasLength(2));
      expect(
        staging.map(
          (dir) =>
              File(p.join(dir.path, 'contents', '漫画 01.png')).readAsBytesSync(),
        ),
        unorderedEquals([
          [1, 2],
          [3, 4],
        ]),
      );
      paths[0].complete(p.join(root.path, 'first.png'));
      // Either asynchronous write can reach the dialog first. Completing one
      // operation must leave the other operation's source intact.
      await _until(() => cache.listSync().whereType<Directory>().length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(cache.listSync().whereType<Directory>(), hasLength(1));
      expect(interaction.IO.isSelectingFiles, isTrue);
      paths[1].complete(p.join(root.path, 'second.png'));
      expect(await Future.wait([first, second]), [true, true]);
      expect(
        [
          File(p.join(root.path, 'first.png')).readAsBytesSync(),
          File(p.join(root.path, 'second.png')).readAsBytesSync(),
        ],
        unorderedEquals([
          [1, 2],
          [3, 4],
        ]),
      );
      expect(original.readAsBytesSync(), [9]);
      expect(cache.listSync().whereType<Directory>(), isEmpty);
      await entered.close();
    },
  );

  test(
    'cancel during source write joins the write and skips native UI',
    () async {
      final writing = Completer<void>();
      final release = Completer<void>();
      final cancelled = StateError('save cancelled');
      var stopped = false;
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(_selector, (_) async {
        nativeCalls++;
        return null;
      });
      final overrides = _FileOverrides(
        cache.path,
        write: (file, bytes, mode, flush) async {
          writing.complete();
          await release.future;
          return file.writeAsBytes(bytes, mode: mode, flush: flush);
        },
      );
      final saving = IOOverrides.runWithIOOverrides(
        () => _saveFile(
          data: Uint8List.fromList([1, 2, 3]),
          filename: 'cancelled.png',
          checkStop: () {
            if (stopped) throw cancelled;
          },
        ),
        overrides,
      );
      var finished = false;
      final checked = expectLater(saving, throwsA(same(cancelled))).then((_) {
        finished = true;
      });
      await writing.future;
      stopped = true;
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(cache.listSync(), hasLength(1));
      release.complete();
      await checked;
      expect(nativeCalls, 0);
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'desktop save waits for XFile.saveTo before releasing its source',
    () async {
      final copying = Completer<void>();
      final release = Completer<void>();
      File? source;
      messenger.setMockMethodCallHandler(
        _selector,
        (_) async => p.join(root.path, 'destination.png'),
      );
      final overrides = _FileOverrides(
        cache.path,
        copy: (file, destination) async {
          source = file;
          copying.complete();
          await release.future;
          return file.copy(destination);
        },
      );
      final owner = SelectionOperation();
      var done = false;
      final saving =
          IOOverrides.runWithIOOverrides(
            () => _saveFile(
              owner: owner,
              data: Uint8List.fromList([1]),
              filename: 'a.png',
            ),
            overrides,
          ).then((result) {
            done = true;
            return result;
          });
      await copying.future;
      expect(done, isFalse);
      expect(source!.existsSync(), isTrue);
      expect(interaction.IO.isSelectingFiles, isTrue);
      var closed = false;
      final closing = owner.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      expect(await saving, isTrue);
      await closing;
      expect(source!.existsSync(), isFalse);
      expect(File(p.join(root.path, 'destination.png')).readAsBytesSync(), [1]);
    },
  );

  for (final cancel in [false, true]) {
    test('caller file remains caller-owned; cancelled=$cancel', () async {
      final caller = File(p.join(cache.path, 'caller.bin'))
        ..writeAsBytesSync([5, 6]);
      messenger.setMockMethodCallHandler(_selector, (call) async {
        expect(call.arguments['suggestedName'], 'renamed.dat');
        return cancel ? null : p.join(root.path, 'renamed.dat');
      });
      expect(await _saveFile(file: caller, filename: 'renamed.dat'), !cancel);
      expect(caller.readAsBytesSync(), [5, 6]);
      expect(cache.listSync(), hasLength(1));
    });
  }

  test(
    'cancellation cleans generated source without touching same-name file',
    () async {
      final caller = File(p.join(cache.path, 'a.png'))..writeAsBytesSync([8]);
      messenger.setMockMethodCallHandler(_selector, (_) async => null);
      expect(
        await _saveFile(
          data: Uint8List.fromList([1]),
          file: caller,
          filename: 'a.png',
        ),
        isFalse,
      );
      expect(caller.readAsBytesSync(), [8]);
      expect(cache.listSync(), hasLength(1));
    },
  );

  test(
    'desktop dialog error preserves its platform failure and cleans source',
    () async {
      messenger.setMockMethodCallHandler(_selector, (_) async {
        throw PlatformException(code: 'save-failed', message: 'dialog failed');
      });
      await expectLater(
        _saveFile(data: Uint8List.fromList([1]), filename: 'a.png'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'save-failed'),
        ),
      );
      expect(cache.listSync(), isEmpty);
    },
  );

  test(
    'selection grace from one operation cannot clear another selection',
    () async {
      final selected = Completer<dynamic>();
      final selecting = Completer<void>();
      messenger.setMockMethodCallHandler(_selector, (call) {
        if (call.method == 'getSavePath') return Future.value(null);
        selecting.complete();
        return selected.future;
      });
      await _saveFile(data: Uint8List(0), filename: 'empty.dat');
      expect(interaction.IO.isSelectingFiles, isTrue);
      final picking = interaction.selectFile(ext: ['png']);
      await selecting.future;
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(interaction.IO.isSelectingFiles, isTrue);
      selected.complete(null);
      expect(await picking, isNull);
      expect(interaction.IO.isSelectingFiles, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(interaction.IO.isSelectingFiles, isFalse);
    },
  );

  for (final kind in ['multiple', 'picker']) {
    test(
      'save keeps selection ownership after $kind selection completes',
      () async {
        final destination = Completer<String?>();
        final savingStarted = Completer<void>();
        messenger.setMockMethodCallHandler(_selector, (call) {
          if (call.method == 'getSavePath') {
            savingStarted.complete();
            return destination.future;
          }
          return Future.value(null);
        });
        messenger.setMockMethodCallHandler(_iosDirectory, (_) async => null);
        final saving = _saveFile(data: Uint8List(0), filename: 'a.dat');
        await savingStarted.future;
        switch (kind) {
          case 'multiple':
            await interaction.selectFiles(ext: ['png']);
          case 'picker':
            await interaction.DirectoryPicker().pickDirectory();
        }
        await Future<void>.delayed(const Duration(milliseconds: 130));
        expect(interaction.IO.isSelectingFiles, isTrue);
        destination.complete(null);
        expect(await saving, isFalse);
      },
    );
  }

  test(
    'owned source waits for asynchronous cleanup after save completes',
    () async {
      final deleting = Completer<void>();
      final release = Completer<void>();
      final directory = _CacheDirectory(cache, (created) async {
        deleting.complete();
        await release.future;
        return created.delete(recursive: true);
      });
      var done = false;
      final saving =
          withSaveFileSource(
            data: Uint8List(0),
            filename: 'a.dat',
            cacheDirectory: directory,
            save: (_) async => false,
          ).then((result) {
            done = true;
            return result;
          });
      await deleting.future;
      expect(done, isFalse);
      expect(cache.listSync(), hasLength(1));
      release.complete();
      expect(await saving, isFalse);
      expect(cache.listSync(), isEmpty);
    },
  );

  for (final stage in ['write', 'copy', 'platform']) {
    for (final cleanupFails in [false, true]) {
      test(
        '$stage failure retains its stack; cleanup failure=$cleanupFails',
        () async {
          final error = StateError('$stage failed');
          final stack = StackTrace.fromString('original $stage stack');
          final cleanupError = StateError('cleanup failed');
          final cleanupStack = StackTrace.fromString('original cleanup stack');
          final caller = File(p.join(root.path, 'caller.dat'))
            ..writeAsBytesSync([4]);
          final directory = _CacheDirectory(cache, (created) async {
            if (cleanupFails) {
              Error.throwWithStackTrace(cleanupError, cleanupStack);
            }
            return created.delete(recursive: true);
          });
          final overrides = _FileOverrides(
            cache.path,
            write: stage == 'write'
                ? (_, _, _, _) => Future.error(error, stack)
                : null,
          );
          final source = stage == 'copy'
              ? _InterceptedFile(
                  caller,
                  copy: (_, _) => Future.error(error, stack),
                )
              : caller;
          Object? caught;
          StackTrace? caughtStack;
          var platformEntered = false;
          try {
            await IOOverrides.runWithIOOverrides(
              () => withSaveFileSource(
                data: stage == 'copy' ? null : Uint8List.fromList([1]),
                file: source,
                filename: 'a.dat',
                copySource: stage == 'copy',
                cacheDirectory: directory,
                save: (_) {
                  platformEntered = true;
                  return Future.error(error, stack);
                },
              ),
              overrides,
            );
            fail('Expected $stage failure');
          } catch (failure, failureStack) {
            caught = failure;
            caughtStack = failureStack;
          }
          expect(platformEntered, stage == 'platform');
          if (cleanupFails) {
            expect(caught, isA<SelectionCleanupFailure>());
            final combined = caught as SelectionCleanupFailure;
            final cleanup =
                combined.failures.single as DirectorySelectionCleanupFailure;
            expect(combined.operationError, same(error));
            expect(combined.operationStack.toString(), stack.toString());
            expect(cleanup.cleanupError, same(cleanupError));
            expect(cleanup.cleanupStack.toString(), cleanupStack.toString());
          } else {
            expect(caught, same(error));
            expect(caughtStack.toString(), stack.toString());
            expect(cache.listSync(), isEmpty);
          }
          expect(caller.readAsBytesSync(), [4]);
        },
      );
    }
  }

  test('cleanup-only failure is not replaced by a save failure', () async {
    final error = StateError('cleanup');
    final stack = StackTrace.fromString('cleanup-only stack');
    final directory = _CacheDirectory(cache, (_) => Future.error(error, stack));
    try {
      await withSaveFileSource(
        data: Uint8List(0),
        filename: 'a.dat',
        cacheDirectory: directory,
        save: (_) async => true,
      );
      fail('Expected cleanup failure');
    } catch (actual) {
      expect(actual, isA<SelectionCleanupFailure>());
      final failure = actual as SelectionCleanupFailure;
      expect(failure.operationError, isNull);
      final cleanup =
          failure.failures.single as DirectorySelectionCleanupFailure;
      expect(cleanup.cleanupError, same(error));
      expect(cleanup.cleanupStack.toString(), stack.toString());
    }
  });

  test('filename paths cannot escape the unique staging directory', () async {
    final caller = File(p.join(root.path, 'outside.dat'))
      ..writeAsBytesSync([9]);
    await withSaveFileSource(
      data: Uint8List.fromList([1]),
      filename: r'..\outside.dat',
      cacheDirectory: cache,
      save: (source) async {
        expect(p.basename(source.path), 'outside.dat');
        expect(p.isWithin(cache.path, source.path), isTrue);
        return true;
      },
    );
    expect(caller.readAsBytesSync(), [9]);
    expect(cache.listSync(), isEmpty);
  });

  test(
    'mobile queue joins real channel returns and preserves caller sources',
    () async {
      final queue = PlatformDialogQueue();
      final replies = <Completer<String?>>[];
      final invoked = <String>[];
      final caller = File(p.join(root.path, 'original.bin'))
        ..writeAsBytesSync([7]);
      messenger.setMockMethodCallHandler(_mobile, (call) {
        expect(call.method, 'saveFile');
        final source = call.arguments['sourceFilePath'] as String;
        expect(call.arguments['fileName'], isNull);
        expect(p.basename(source), 'export.venera');
        expect(File(source).readAsBytesSync(), [7]);
        invoked.add(source);
        final reply = Completer<String?>();
        replies.add(reply);
        return reply.future;
      });
      Future<bool> save([SelectionOperation? owner]) => withSaveFileSource(
        owner: owner,
        file: caller,
        filename: 'export.venera',
        copySource: true,
        cacheDirectory: cache,
        save: (source) => queue.run(() async {
          final result = await FlutterFileDialog.saveFile(
            params: SaveFileDialogParams(sourceFilePath: source.path),
          );
          return result != null;
        }),
      );
      final owner = SelectionOperation();
      final first = save(owner);
      await _until(() => replies.length == 1);
      var secondDone = false;
      final second = save().then((result) {
        secondDone = true;
        return result;
      });
      await _until(() => replies.length == 1 && cache.listSync().length == 2);
      expect(secondDone, isFalse);
      expect(File(invoked.single).existsSync(), isTrue);
      expect(caller.existsSync(), isTrue);
      var closed = false;
      final closing = owner.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      replies[0].complete(null);
      expect(await first, isFalse);
      await closing;
      await _until(() => replies.length == 2);
      expect(invoked[0], isNot(invoked[1]));
      expect(File(invoked[0]).existsSync(), isFalse);
      expect(File(invoked[1]).existsSync(), isTrue);
      expect(secondDone, isFalse);
      replies[1].complete('saved');
      expect(await second, isTrue);
      expect(cache.listSync(), isEmpty);
      expect(caller.readAsBytesSync(), [7]);
    },
  );

  test(
    'mobile queue admits the next operation after an original failure',
    () async {
      final queue = PlatformDialogQueue();
      final first = Completer<bool>();
      var calls = 0;
      final failed = queue.run(() {
        calls++;
        return first.future;
      });
      final next = queue.run(() async {
        calls++;
        return true;
      });
      final checked = expectLater(failed, throwsA(isA<StateError>()));
      await pumpEventQueue();
      expect(calls, 1);
      first.completeError(StateError('native failure'));
      await checked;
      expect(await next, isTrue);
      expect(calls, 2);
    },
  );
}

Future<void> _until(bool Function() complete) async {
  for (var i = 0; i < 400 && !complete(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(complete(), isTrue);
}

final class _FileOverrides extends IOOverrides {
  _FileOverrides(this.directory, {this.copy, this.write});
  final _nativeZone = Zone.current;
  final String directory;
  final Future<File> Function(File, String)? copy;
  final Future<File> Function(File, List<int>, FileMode, bool)? write;

  // Dart 3.11 on Windows reports notFound from the default IOOverrides type
  // adapter even for an existing directory. Only intercept the intended file
  // operations; query real entity types in the original zone.
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _nativeZone.run(
        () => FileSystemEntity.type(path, followLinks: followLinks),
      );

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.isWithin(directory, path) && p.basename(path) != '.selection-owner'
        ? _InterceptedFile(file, copy: copy, write: write)
        : file;
  }
}

class _InterceptedFile implements File {
  _InterceptedFile(
    this.raw, {
    Future<File> Function(File, String)? copy,
    this.write,
  }) : _copy = copy;
  final File raw;
  final Future<File> Function(File, String)? _copy;
  final Future<File> Function(File, List<int>, FileMode, bool)? write;
  @override
  String get path => raw.path;
  @override
  Future<File> copy(String path) => _copy?.call(raw, path) ?? raw.copy(path);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) =>
      write?.call(raw, bytes, mode, flush) ??
      raw.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CacheDirectory implements Directory {
  _CacheDirectory(this.raw, this.remove);
  final Directory raw;
  final Future<FileSystemEntity> Function(Directory) remove;
  @override
  String get path => raw.path;
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _OwnedDirectory(await raw.createTemp(prefix), remove);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OwnedDirectory implements Directory {
  _OwnedDirectory(this.raw, this.remove);
  final Directory raw;
  final Future<FileSystemEntity> Function(Directory) remove;
  @override
  String get path => raw.path;
  @override
  Future<String> resolveSymbolicLinks() => raw.resolveSymbolicLinks();
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => raw.list(recursive: recursive, followLinks: followLinks);
  @override
  Future<Directory> delete({bool recursive = false}) async {
    expect(recursive, isFalse);
    await remove(raw);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<bool> _saveFile({
  Uint8List? data,
  File? file,
  required String filename,
  void Function()? checkStop,
  SelectionOperation? owner,
}) => (owner ?? SelectionOperation()).run(
  (operation) => interaction.saveFile(
    operation: operation,
    data: data,
    file: file,
    filename: filename,
    checkStop: checkStop,
  ),
);

Future<bool> withSaveFileSource({
  Uint8List? data,
  File? file,
  required String filename,
  required Directory cacheDirectory,
  required Future<bool> Function(File) save,
  bool copySource = false,
  void Function()? checkStop,
  SelectionOperation? owner,
}) => (owner ?? SelectionOperation()).run(
  (operation) => saves.withSaveFileSource(
    operation: operation,
    data: data,
    file: file,
    filename: filename,
    cacheDirectory: cacheDirectory,
    save: save,
    copySource: copySource,
    checkStop: checkStop,
  ),
);
