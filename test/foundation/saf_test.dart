import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_saf/src/backend.dart';
import 'package:venera_saf/venera_saf.dart';

const _root = 'android://primary:漫画/授权根';
const _alias = 'android://secondary:镜像根';

final class _TrackedFile extends Fake implements RandomAccessFile {
  _TrackedFile(this.file, this.backend);
  final RandomAccessFile file;
  final _HostBackend backend;
  @override
  Uint8List readSync(int count) => file.readSync(count);
  @override
  Future<Uint8List> read(int count) => file.read(count);
  @override
  void setPositionSync(int position) => file.setPositionSync(position);
  @override
  Future<RandomAccessFile> setPosition(int position) =>
      file.setPosition(position);
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if (backend.failWrite) {
      throw const FileSystemException('primary write failure');
    }
    file.writeFromSync(buffer, start, end);
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    writeFromSync(buffer, start, end);
    return this;
  }

  @override
  void flushSync() => file.flushSync();
  @override
  void closeSync() {
    file.closeSync();
    backend.opens--;
    if (backend.failClose) {
      throw const FileSystemException('secondary close failure');
    }
  }

  @override
  Future<void> close() async => closeSync();
}

final class _HostBackend extends SafBackend {
  _HostBackend(this.root);
  final Directory root;
  int opens = 0;
  bool failWrite = false;
  bool failClose = false;
  bool cycle = false;

  String local(String path) {
    final grant = path == _alias || path.startsWith('$_alias/')
        ? _alias
        : _root;
    if (path != grant && !path.startsWith('$grant/')) {
      throw FileSystemException(
        'No persistent directory permission',
        path,
        const OSError('Denied', 13),
      );
    }
    if (path == grant) return root.path;
    return '${root.path}${Platform.pathSeparator}${path.substring(grant.length + 1).split('/').map(Uri.encodeComponent).join(Platform.pathSeparator)}';
  }

  Map<String, dynamic> stat(String saf, String real) {
    final value = FileStat.statSync(real);
    return {
      'path': saf,
      'identity': real,
      'type': value.type == FileSystemEntityType.directory
          ? 'directory'
          : value.type == FileSystemEntityType.file
          ? 'file'
          : 'notFound',
      'size': value.size,
      'modified': value.modified.millisecondsSinceEpoch,
    };
  }

  @override
  Map<String, dynamic> invoke(Map<String, dynamic> request) {
    final path = request['path'] as String;
    final real = local(path);
    switch (request['op']) {
      case 'stat':
        return stat(path, real);
      case 'parent':
        return {
          'path': path == _root || path == _alias
              ? safPrefix
              : path.substring(0, path.lastIndexOf('/')),
        };
      case 'list':
        return {
          'entries': cycle
              ? [stat('$_root/cycle', root.path)]
              : Directory(real)
                    .listSync()
                    .map(
                      (file) => stat(
                        '$path/${Uri.decodeComponent(file.path.split(Platform.pathSeparator).last)}',
                        file.path,
                      ),
                    )
                    .toList(),
        };
      case 'create':
        if (request['directory'] == true) {
          Directory(real).createSync(recursive: request['recursive'] as bool);
        } else {
          File(real).createSync(recursive: request['recursive'] as bool);
        }
        return stat(path, real);
      case 'delete':
        if (path == _root || path == _alias) {
          throw const FileSystemException('Authorized roots cannot be deleted');
        }
        if (request['directory'] == true) {
          Directory(real).deleteSync(recursive: request['recursive'] as bool);
        } else {
          File(real).deleteSync();
        }
        return {};
      case 'rename':
        final target = local(request['target'] as String);
        if (FileSystemEntity.typeSync(target) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('Rename target already exists');
        }
        if (request['directory'] == true) {
          Directory(real).renameSync(target);
        } else {
          File(real).renameSync(target);
        }
        return {};
      default:
        throw StateError('Unexpected host adapter request $request');
    }
  }

  @override
  RandomAccessFile openSync(String path, FileMode mode) {
    final file = File(local(path)).openSync(mode: mode);
    opens++;
    return _TrackedFile(file, this);
  }
}

int _workerIdentity() => Isolate.current.hashCode;
Never _workerFailure() =>
    throw const FileSystemException('provider failure', 'android://lost');
void _workerExit() => Isolate.exit();
Future<int> _delayedResult() async {
  await Future<void>.delayed(const Duration(milliseconds: 40));
  return 73;
}

void main() {
  late Directory temporary;
  late _HostBackend backend;
  late SafBackend previous;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('venera-saf-adapter-');
    backend = _HostBackend(temporary);
    previous = setSafBackendForTesting(backend);
  });
  tearDown(() async {
    await SAFTaskWorker().dispose();
    setSafBackendForTesting(previous);
    expect(backend.opens, 0);
    temporary.deleteSync(recursive: true);
  });

  test(
    'recognizes stored document IDs without treating them as URI authorities',
    () {
      final root = AndroidDirectory.fromPathSync(_root)!;
      expect(root.path, _root);
      expect(root.parent.path, safPrefix);
      expect(root.existsSync(), isTrue);
      expect(AndroidFile.fromPathSync(temporary.path), isNull);
      expect(
        AndroidDirectory.fromPathSync('android://missing:grant'),
        isNotNull,
      );
      expect(
        () => AndroidDirectory.fromPathSync(
          'android://missing:grant',
        )!.existsSync(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('zone override leaves ordinary file and type queries working', () async {
    await IOOverrides.runWithIOOverrides(() async {
      expect(Directory(_root), isA<AndroidDirectory>());
      expect(File('$_root/文件'), isA<AndroidFile>());
      expect(FileSystemEntity.typeSync(_root), FileSystemEntityType.directory);
      expect(
        await FileSystemEntity.type(temporary.path),
        FileSystemEntityType.directory,
      );
      final ordinary = File(
        '${temporary.path}${Platform.pathSeparator}ordinary',
      );
      await ordinary.writeAsString('normal');
      expect(await ordinary.readAsString(), 'normal');
    }, SafIOOverrides(enabled: true));
  });

  test(
    'Unicode names, typed views, append and existing create retain bytes',
    () async {
      final directory = AndroidDirectory.fromPathSync('$_root/章节:📖|中文')!;
      await directory.create();
      final file = AndroidFile.fromPathSync('${directory.path}/页:😀|1.txt')!;
      final bytes = Uint8List.fromList([99, 1, 2, 3, 98]);
      await file.writeAsBytes(Uint8List.sublistView(bytes, 1, 4), flush: true);
      file.createSync();
      expect(file.readAsBytesSync(), [1, 2, 3]);
      await file.writeAsString('中文\n😀', mode: FileMode.append);
      expect((await file.readAsBytes()).take(3), [1, 2, 3]);
      expect(directory.listSync().single.path, file.path);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(3));
    },
  );

  test('stream ranges and cancellation close provider handles', () async {
    final file = AndroidFile.fromPathSync('$_root/stream')!;
    await file.writeAsBytes(List.generate(150000, (i) => i % 256));
    final range = await file.openRead(17, 26).expand((bytes) => bytes).toList();
    expect(range, List.generate(9, (i) => i + 17));
    expect((await file.openRead().first).length, 65536);
    expect(backend.opens, 0);
  });

  test(
    'empty sink creates a file and write errors survive failing cleanup',
    () async {
      final empty = AndroidFile.fromPathSync('$_root/empty')!;
      await empty.openWrite().close();
      expect(await empty.length(), 0);
      backend.failWrite = true;
      backend.failClose = true;
      final file = AndroidFile.fromPathSync('$_root/failing')!;
      expect(
        () => file.writeAsBytesSync([1]),
        throwsA(
          predicate(
            (error) => error.toString().contains('primary write failure'),
          ),
        ),
      );
      final sink = file.openWrite();
      sink.done.ignore();
      await expectLater(
        sink.addStream(Stream.value([1])),
        throwsA(
          predicate(
            (error) => error.toString().contains('primary write failure'),
          ),
        ),
      );
      try {
        await sink.close();
      } catch (_) {}
    },
  );

  test(
    'copy and same-directory rename preserve contents and refuse collisions',
    () async {
      final file = AndroidFile.fromPathSync('$_root/original')!;
      await file.writeAsString('export');
      final copied = await file.copy(
        '${temporary.path}${Platform.pathSeparator}copy',
      );
      expect(await copied.readAsString(), 'export');
      final renamed = await file.rename('$_root/renamed');
      expect(await renamed.readAsString(), 'export');
      expect(file.existsSync(), isFalse);
      final collision = AndroidFile.fromPathSync('$_root/collision')!
        ..writeAsStringSync('keep');
      await expectLater(
        renamed.rename(collision.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(collision.readAsStringSync(), 'keep');
    },
  );

  test('unsupported operations and directory cycles fail explicitly', () {
    final root = AndroidDirectory.fromPathSync(_root)!;
    expect(() => root.createTempSync(), throwsA(isA<FileSystemException>()));
    expect(() => root.watch(), throwsA(isA<FileSystemException>()));
    expect(
      () =>
          AndroidFile.fromPathSync('$_root/file')!.createSync(exclusive: true),
      throwsA(isA<FileSystemException>()),
    );
    backend.cycle = true;
    expect(
      () => root.listSync(recursive: true),
      throwsA(
        predicate((error) => error.toString().contains('directory cycle')),
      ),
    );
  });

  test('copy rejects normalized paths and aliases before truncation', () async {
    final file = AndroidFile.fromPathSync('$_root/original')!
      ..writeAsStringSync('retain 中文😀');
    for (final target in [file.path, '${file.path}/', '$_alias/original']) {
      expect(() => file.copySync(target), throwsA(isA<FileSystemException>()));
      await expectLater(file.copy(target), throwsA(isA<FileSystemException>()));
      expect(file.readAsStringSync(), 'retain 中文😀');
      expect(backend.opens, 0);
    }
    final copied = await file.copy('$_alias/copied');
    expect(await copied.readAsString(), 'retain 中文😀');
  });

  test('copy preserves its write error when sink cleanup fails', () async {
    final file = AndroidFile.fromPathSync('$_root/original')!
      ..writeAsBytesSync(List.filled(150000, 42));
    backend.failWrite = true;
    backend.failClose = true;
    await expectLater(
      file.copy('$_root/failing-copy'),
      throwsA(
        predicate(
          (error) => error.toString().contains('primary write failure'),
        ),
      ),
    );
  });

  test(
    'worker initializes once, returns exceptions with stacks, and restarts',
    () async {
      final worker = SAFTaskWorker();
      await Future.wait(List.generate(8, (_) => worker.init()));
      final identities = await Future.wait(
        List.generate(8, (_) => worker.runTask<int>(_workerIdentity, [])),
      );
      expect(identities.toSet(), hasLength(1));
      await expectLater(
        worker.runTask<void>(_workerFailure, []),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.path,
            'path',
            'android://lost',
          ),
        ),
      );
      try {
        await worker.runTask<void>(_workerFailure, []);
      } catch (_, stack) {
        expect(stack.toString(), contains('_workerFailure'));
      }
      await worker.dispose();
      await worker.init();
      expect(await worker.runTask<int>(_workerIdentity, []), isA<int>());
    },
  );

  test('worker disposal drains running work and rejects new tasks', () async {
    final worker = SAFTaskWorker();
    await worker.init();
    final running = worker.runTask<int>(_delayedResult, []);
    await Future<void>.delayed(Duration.zero);
    final closing = worker.dispose();
    await expectLater(
      worker.runTask<int>(_workerIdentity, []),
      throwsStateError,
    );
    expect(await running, 73);
    await closing;
  });

  test('unexpected worker exit fails pending tasks and allows retry', () async {
    final worker = SAFTaskWorker();
    await expectLater(worker.runTask<void>(_workerExit, []), throwsStateError);
    expect(await worker.runTask<int>(_workerIdentity, []), isA<int>());
  });
}
