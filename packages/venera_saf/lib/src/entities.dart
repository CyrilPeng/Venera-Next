// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'backend.dart';

abstract class _SafEntity implements FileSystemEntity {
  _SafEntity(String value) : path = safPath(value);

  @override
  final String path;
  @override
  bool get isAbsolute => true;
  @override
  Uri get uri => Uri(scheme: 'android', path: path.substring(safPrefix.length));

  Map<String, dynamic> request(
    String operation, [
    Map<String, dynamic>? extra,
  ]) => {'op': operation, 'path': path, ...?extra};

  @override
  FileStat statSync() => SafStat(safBackend.invoke(request('stat')));
  @override
  Future<FileStat> stat() async =>
      SafStat(await safBackend.invokeAsync(request('stat')));

  @override
  Directory get parent => AndroidDirectory._(
    safBackend.invoke(request('parent'))['path'] as String,
  );

  @override
  String resolveSymbolicLinksSync() {
    if (statSync().type == FileSystemEntityType.notFound) {
      throw FileSystemException('Document does not exist', path);
    }
    return path;
  }

  @override
  Future<String> resolveSymbolicLinks() async {
    if ((await stat()).type == FileSystemEntityType.notFound) {
      throw FileSystemException('Document does not exist', path);
    }
    return path;
  }

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => safUnsupported('Filesystem watching', path);
}

class AndroidDirectory extends _SafEntity implements Directory {
  AndroidDirectory._(super.value);

  static AndroidDirectory? fromPathSync(String path) =>
      isSafPath(path) ? AndroidDirectory._(path) : null;
  static Future<AndroidDirectory?> fromPath(String path) =>
      Future.sync(() => fromPathSync(path));

  static Future<AndroidDirectory?> pickDirectory() async {
    if (!Platform.isAndroid) safUnsupported('Directory picker', safPrefix);
    final path = await const MethodChannel(
      'venera/saf',
    ).invokeMethod<String>('pickDirectory');
    return path == null ? null : AndroidDirectory._(path);
  }

  @override
  Directory get absolute => this;
  @override
  bool existsSync() => statSync().type == FileSystemEntityType.directory;
  @override
  Future<bool> exists() async =>
      (await stat()).type == FileSystemEntityType.directory;

  @override
  void createSync({bool recursive = false}) {
    safBackend.invoke(
      request('create', {'directory': true, 'recursive': recursive}),
    );
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    await safBackend.invokeAsync(
      request('create', {'directory': true, 'recursive': recursive}),
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) {
    safBackend.invoke(
      request('delete', {'directory': true, 'recursive': recursive}),
    );
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await safBackend.invokeAsync(
      request('delete', {'directory': true, 'recursive': recursive}),
    );
    return this;
  }

  List<Map<String, dynamic>> _childrenSync() =>
      (safBackend.invoke(request('list'))['entries'] as List)
          .cast<Map<String, dynamic>>();

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    final result = <FileSystemEntity>[];
    void visit(AndroidDirectory directory, Set<String> parents) {
      for (final entry in directory._childrenSync()) {
        final child = entry['type'] == 'directory'
            ? AndroidDirectory._(entry['path'] as String)
            : AndroidFile._(entry['path'] as String);
        result.add(child);
        if (recursive && child is AndroidDirectory) {
          final identity = entry['identity'] as String;
          if (parents.contains(identity)) {
            throw FileSystemException(
              'Document provider contains a directory cycle',
              child.path,
            );
          }
          visit(child, {...parents, identity});
        }
      }
    }

    visit(this, {
      safBackend.invoke(request('stat'))['identity'] as String? ?? path,
    });
    return result;
  }

  Stream<FileSystemEntity> _listRecursive(
    bool recursive,
    Set<String> parents,
  ) async* {
    final entries =
        (await safBackend.invokeAsync(request('list')))['entries'] as List;
    for (final entry in entries.cast<Map<String, dynamic>>()) {
      final child = entry['type'] == 'directory'
          ? AndroidDirectory._(entry['path'] as String)
          : AndroidFile._(entry['path'] as String);
      yield child;
      if (recursive && child is AndroidDirectory) {
        final identity = entry['identity'] as String;
        if (parents.contains(identity)) {
          throw FileSystemException(
            'Document provider contains a directory cycle',
            child.path,
          );
        }
        yield* child._listRecursive(true, {...parents, identity});
      }
    }
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    final identity =
        (await safBackend.invokeAsync(request('stat')))['identity']
            as String? ??
        path;
    yield* _listRecursive(recursive, {identity});
  }

  @override
  Directory renameSync(String newPath) {
    final target = safPath(newPath);
    safBackend.invoke(request('rename', {'target': target, 'directory': true}));
    return AndroidDirectory._(target);
  }

  @override
  Future<Directory> rename(String newPath) async {
    final target = safPath(newPath);
    await safBackend.invokeAsync(
      request('rename', {'target': target, 'directory': true}),
    );
    return AndroidDirectory._(target);
  }

  @override
  Directory createTempSync([String? prefix]) =>
      safUnsupported('Atomic temporary-directory creation', path);
  @override
  Future<Directory> createTemp([String? prefix]) =>
      Future.sync(() => createTempSync(prefix));
}

class AndroidFile extends _SafEntity implements File {
  AndroidFile._(super.value);

  static AndroidFile? fromPathSync(String path) =>
      isSafPath(path) ? AndroidFile._(path) : null;
  static Future<AndroidFile?> fromPath(String path) =>
      Future.sync(() => fromPathSync(path));

  @override
  File get absolute => this;
  @override
  bool existsSync() => statSync().type == FileSystemEntityType.file;
  @override
  Future<bool> exists() async =>
      (await stat()).type == FileSystemEntityType.file;
  @override
  int lengthSync() {
    final value = statSync();
    if (value.type != FileSystemEntityType.file) {
      throw FileSystemException('File does not exist', path);
    }
    if (value.size < 0) safUnsupported('Unknown provider file length', path);
    return value.size;
  }

  @override
  Future<int> length() async {
    final value = await stat();
    if (value.type != FileSystemEntityType.file) {
      throw FileSystemException('File does not exist', path);
    }
    if (value.size < 0) safUnsupported('Unknown provider file length', path);
    return value.size;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    if (exclusive) safUnsupported('Atomic exclusive file creation', path);
    safBackend.invoke(
      request('create', {'directory': false, 'recursive': recursive}),
    );
  }

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    if (exclusive) safUnsupported('Atomic exclusive file creation', path);
    await safBackend.invokeAsync(
      request('create', {'directory': false, 'recursive': recursive}),
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) {
    safBackend.invoke(
      request('delete', {'directory': false, 'recursive': recursive}),
    );
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await safBackend.invokeAsync(
      request('delete', {'directory': false, 'recursive': recursive}),
    );
    return this;
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      safBackend.openSync(path, mode);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      safBackend.open(path, mode);

  @override
  Uint8List readAsBytesSync() {
    final file = openSync();
    final bytes = BytesBuilder(copy: false);
    var failed = false;
    try {
      while (true) {
        final chunk = file.readSync(64 * 1024);
        if (chunk.isEmpty) break;
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (failed) {
        try {
          file.closeSync();
        } catch (_) {}
      } else {
        file.closeSync();
      }
    }
  }

  @override
  Future<Uint8List> readAsBytes() => safBackend.readAll(path);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      encoding.decode(readAsBytesSync());
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());
  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      const LineSplitter().convert(readAsStringSync(encoding: encoding));
  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      const LineSplitter().convert(await readAsString(encoding: encoding));

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    final file = openSync(mode: mode);
    var failed = false;
    try {
      file.writeFromSync(bytes);
      if (flush) file.flushSync();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (failed) {
        try {
          file.closeSync();
        } catch (_) {}
      } else {
        file.closeSync();
      }
    }
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await safBackend.writeAll(path, bytes, mode, flush);
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytesSync(encoding.encode(contents), mode: mode, flush: flush);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if ((start != null && start < 0) || (end != null && end < (start ?? 0))) {
      throw RangeError('Invalid file read range');
    }
    final file = await open();
    var failed = false;
    try {
      if (start != null && start != 0) await file.setPosition(start);
      var position = start ?? 0;
      while (end == null || position < end) {
        final count = end == null || end - position > 64 * 1024
            ? 64 * 1024
            : end - position;
        final bytes = await file.read(count);
        if (bytes.isEmpty) break;
        position += bytes.length;
        yield bytes;
      }
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (failed) {
        try {
          await file.close();
        } catch (_) {}
      } else {
        await file.close();
      }
    }
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    safMode(mode);
    return IOSink(_SafConsumer(this, mode), encoding: encoding);
  }

  File _target(String newPath) {
    final target = AndroidFile.fromPathSync(newPath) ?? File(newPath);
    if (target.path == path) {
      throw FileSystemException('Source and destination are equal', path);
    }
    return target;
  }

  void _checkCopyIdentity(
    Map<String, dynamic> source,
    Map<String, dynamic> target,
  ) {
    final identity = source['identity'];
    if (identity != null && identity == target['identity']) {
      throw FileSystemException(
        'Source and destination refer to the same document',
        path,
      );
    }
  }

  @override
  File copySync(String newPath) {
    final target = _target(newPath);
    if (target is AndroidFile) {
      _checkCopyIdentity(
        safBackend.invoke(request('stat')),
        safBackend.invoke(target.request('stat')),
      );
    }
    final input = openSync();
    RandomAccessFile? output;
    var failed = false;
    try {
      output = target.openSync(mode: FileMode.write);
      while (true) {
        final bytes = input.readSync(64 * 1024);
        if (bytes.isEmpty) break;
        output.writeFromSync(bytes);
      }
      return target;
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (failed) {
        try {
          output?.closeSync();
        } catch (_) {}
        try {
          input.closeSync();
        } catch (_) {}
      } else {
        try {
          output?.closeSync();
        } finally {
          input.closeSync();
        }
      }
    }
  }

  @override
  Future<File> copy(String newPath) async {
    final target = _target(newPath);
    if (target is AndroidFile) {
      _checkCopyIdentity(
        await safBackend.invokeAsync(request('stat')),
        await safBackend.invokeAsync(target.request('stat')),
      );
    }
    final sink = target.openWrite();
    sink.done.ignore();
    var failed = false;
    try {
      await sink.addStream(openRead());
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (failed) {
        try {
          await sink.close();
        } catch (_) {}
      } else {
        await sink.close();
      }
    }
    return target;
  }

  @override
  File renameSync(String newPath) {
    if (isSafPath(newPath)) {
      safBackend.invoke(
        request('rename', {'target': safPath(newPath), 'directory': false}),
      );
      return AndroidFile._(newPath);
    }
    final result = copySync(newPath);
    deleteSync();
    return result;
  }

  @override
  Future<File> rename(String newPath) async {
    if (isSafPath(newPath)) {
      await safBackend.invokeAsync(
        request('rename', {'target': safPath(newPath), 'directory': false}),
      );
      return AndroidFile._(newPath);
    }
    final result = await copy(newPath);
    await delete();
    return result;
  }

  @override
  DateTime lastModifiedSync() => statSync().modified;
  @override
  Future<DateTime> lastModified() async => (await stat()).modified;
  @override
  DateTime lastAccessedSync() => safUnsupported('Access-time metadata', path);
  @override
  Future<DateTime> lastAccessed() => Future.sync(lastAccessedSync);
  @override
  void setLastAccessedSync(DateTime time) =>
      safUnsupported('Setting access time', path);
  @override
  Future<void> setLastAccessed(DateTime time) =>
      Future.sync(() => setLastAccessedSync(time));
  @override
  void setLastModifiedSync(DateTime time) =>
      safUnsupported('Setting modification time', path);
  @override
  Future<void> setLastModified(DateTime time) =>
      Future.sync(() => setLastModifiedSync(time));
}

final class _SafConsumer implements StreamConsumer<List<int>> {
  _SafConsumer(this.file, this.mode);
  final AndroidFile file;
  final FileMode mode;
  Future<RandomAccessFile>? _opened;
  Future<void>? _closing;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_closing != null) throw StateError('File sink is closed');
    StreamIterator<List<int>>? input;
    var failed = false;
    try {
      final output = await (_opened ??= file.open(mode: mode));
      input = StreamIterator(stream);
      while (await input.moveNext()) {
        await output.writeFrom(input.current);
      }
    } catch (_) {
      failed = true;
      try {
        await close();
      } catch (_) {}
      rethrow;
    } finally {
      if (failed) {
        try {
          await input?.cancel();
        } catch (_) {}
      } else {
        await input?.cancel();
      }
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    final output = await (_opened ??= file.open(mode: mode));
    await output.close();
  }();
}
