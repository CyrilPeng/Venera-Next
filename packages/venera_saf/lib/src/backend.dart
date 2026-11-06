// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'entities.dart';
import 'native_backend.dart';
import 'worker.dart';

const safPrefix = 'android://';

bool isSafPath(String path) => path.startsWith(safPrefix);

String safPath(String path) {
  if (!isSafPath(path) || path.contains('\u0000')) {
    throw FileSystemException('Invalid document-provider path', path);
  }
  while (path.endsWith('/') && path.length > safPrefix.length) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

Never safUnsupported(String operation, String path) =>
    throw FileSystemException(
      '$operation is unavailable for Android document providers',
      path,
      const OSError('Operation not supported', 95),
    );

int safMode(FileMode mode) {
  const modes = [
    FileMode.read,
    FileMode.write,
    FileMode.append,
    FileMode.writeOnly,
    FileMode.writeOnlyAppend,
  ];
  final result = modes.indexOf(mode);
  if (result < 0) safUnsupported('Exclusive descriptor open', safPrefix);
  return result;
}

FileMode fileMode(int mode) => const [
  FileMode.read,
  FileMode.write,
  FileMode.append,
  FileMode.writeOnly,
  FileMode.writeOnlyAppend,
][mode];

abstract class SafBackend {
  Map<String, dynamic> invoke(Map<String, dynamic> request);
  RandomAccessFile openSync(String path, FileMode mode);

  Future<Map<String, dynamic>> invokeAsync(Map<String, dynamic> request) =>
      Future.sync(() => invoke(request));
  Future<RandomAccessFile> open(String path, FileMode mode) =>
      Future.sync(() => openSync(path, mode));
  Future<Uint8List> readAll(String path) => Future.sync(() => readWorker(path));
  Future<void> writeAll(
    String path,
    List<int> bytes,
    FileMode mode,
    bool flush,
  ) => Future.sync(() => writeWorker(path, bytes, safMode(mode), flush));

  bool get runsNatively => false;
}

final class _UnavailableBackend extends SafBackend {
  @override
  Map<String, dynamic> invoke(Map<String, dynamic> request) =>
      safUnsupported('Storage access', request['path'] as String? ?? safPrefix);
  @override
  RandomAccessFile openSync(String path, FileMode mode) =>
      safUnsupported('Storage access', path);
}

SafBackend _backend = Platform.isAndroid
    ? NativeSafBackend()
    : _UnavailableBackend();

SafBackend get safBackend => _backend;

@visibleForTesting
SafBackend setSafBackendForTesting(SafBackend value) {
  final previous = _backend;
  _backend = value;
  return previous;
}

Map<String, dynamic> metadataWorker(Map<String, dynamic> request) =>
    safBackend.invoke(request);

Uint8List readWorker(String path) =>
    AndroidFile.fromPathSync(path)!.readAsBytesSync();

void writeWorker(String path, List<int> bytes, int mode, bool flush) =>
    AndroidFile.fromPathSync(
      path,
    )!.writeAsBytesSync(bytes, mode: fileMode(mode), flush: flush);

Future<T> nativeTask<T>(Function function, List<dynamic> args) =>
    SAFTaskWorker().runTask<T>(function, args);

final class SafStat implements FileStat {
  SafStat(Map<String, dynamic> metadata)
    : type = switch (metadata['type']) {
        'directory' => FileSystemEntityType.directory,
        'file' => FileSystemEntityType.file,
        _ => FileSystemEntityType.notFound,
      },
      size = metadata['size'] as int? ?? -1,
      modified = DateTime.fromMillisecondsSinceEpoch(
        metadata['modified'] as int? ?? 0,
      );

  @override
  final FileSystemEntityType type;
  @override
  final int size;
  @override
  final DateTime modified;
  @override
  DateTime get changed => modified;
  @override
  DateTime get accessed => DateTime.fromMillisecondsSinceEpoch(0);
  @override
  int get mode => type == FileSystemEntityType.directory ? 0x41c0 : 0x8180;
  @override
  String modeString() =>
      type == FileSystemEntityType.directory ? 'rwx------' : 'rw-------';
}
