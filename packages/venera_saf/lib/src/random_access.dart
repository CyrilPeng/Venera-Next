// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backend.dart';
import 'native_backend.dart';

/// Owns the original provider descriptor until close, including its Java
/// ParcelFileDescriptor. Async data operations run in the SAF worker.
final class AndroidRandomAccessFile implements RandomAccessFile {
  AndroidRandomAccessFile(this._lease, this.path);
  final NativeSafDescriptor _lease;
  bool _pending = false;

  @override
  final String path;

  void _check() {
    if (_lease.isClosed) throw FileSystemException('File is closed', path);
    if (_pending) {
      throw FileSystemException(
        'An asynchronous file operation is pending',
        path,
      );
    }
  }

  T _sync<T>(T Function() operation) {
    _check();
    return operation();
  }

  Future<T> _async<T>(Future<T> Function() operation) async {
    _check();
    _pending = true;
    try {
      return await operation();
    } finally {
      _pending = false;
    }
  }

  int _valueSync(int operation, [int value = 0]) =>
      _sync(() => descriptorValueWorker(_lease.token, operation, value, path));
  Future<int> _value(int operation, [int value = 0]) => _async(
    () => nativeTask<int>(descriptorValueWorker, [
      _lease.token,
      operation,
      value,
      path,
    ]),
  );

  @override
  Future<void> close() => _async(() => Future.sync(() => _lease.close(path)));
  @override
  void closeSync() => _sync(() => _lease.close(path));
  @override
  Future<RandomAccessFile> flush() async {
    await _value(4);
    return this;
  }

  @override
  void flushSync() {
    _valueSync(4);
  }

  @override
  Future<int> length() => _value(2);
  @override
  int lengthSync() => _valueSync(2);
  @override
  Future<int> position() => _value(0);
  @override
  int positionSync() => _valueSync(0);
  @override
  Future<Uint8List> read(int count) {
    RangeError.checkNotNegative(count, 'count');
    return _async(
      () => nativeTask<Uint8List>(descriptorReadWorker, [
        _lease.token,
        count,
        path,
      ]),
    );
  }

  @override
  Uint8List readSync(int count) {
    RangeError.checkNotNegative(count, 'count');
    return _sync(() => descriptorReadWorker(_lease.token, count, path));
  }

  @override
  Future<int> readByte() async {
    final bytes = await read(1);
    return bytes.isEmpty ? -1 : bytes[0];
  }

  @override
  int readByteSync() {
    final bytes = readSync(1);
    return bytes.isEmpty ? -1 : bytes[0];
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    final bytes = await read(limit - start);
    buffer.setRange(start, start + bytes.length, bytes);
    return bytes.length;
  }

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    final bytes = readSync(limit - start);
    buffer.setRange(start, start + bytes.length, bytes);
    return bytes.length;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    RangeError.checkNotNegative(position, 'position');
    await _value(1, position);
    return this;
  }

  @override
  void setPositionSync(int position) {
    RangeError.checkNotNegative(position, 'position');
    _valueSync(1, position);
  }

  @override
  Future<RandomAccessFile> truncate(int length) async {
    RangeError.checkNotNegative(length, 'length');
    await _value(3, length);
    return this;
  }

  @override
  void truncateSync(int length) {
    RangeError.checkNotNegative(length, 'length');
    _valueSync(3, length);
  }

  @override
  Future<RandomAccessFile> writeByte(int value) => writeFrom([value]);
  @override
  int writeByteSync(int value) {
    writeFromSync([value]);
    return 1;
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    final bytes = Uint8List.fromList(buffer.sublist(start, limit));
    await _async(
      () =>
          nativeTask<void>(descriptorWriteWorker, [_lease.token, bytes, path]),
    );
    return this;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    _sync(
      () => descriptorWriteWorker(
        _lease.token,
        Uint8List.fromList(buffer.sublist(start, limit)),
        path,
      ),
    );
  }

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) => writeFrom(encoding.encode(string));
  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) =>
      writeFromSync(encoding.encode(string));
  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) => Future.sync(() => safUnsupported('File locking', path));
  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) => safUnsupported('File locking', path);
  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) =>
      Future.sync(() => safUnsupported('File unlocking', path));
  @override
  void unlockSync([int start = 0, int end = -1]) =>
      safUnsupported('File unlocking', path);
}
