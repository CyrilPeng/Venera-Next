// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'random_access.dart';

final _library = DynamicLibrary.open('libvenera_saf.so');
final _metadata = _library
    .lookupFunction<
      Int32 Function(
        Pointer<Uint8>,
        Size,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>,
      ),
      int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>)
    >('venera_saf_metadata');
final _open = _library
    .lookupFunction<
      Pointer<Uint64> Function(
        Pointer<Uint8>,
        Size,
        Int32,
        Pointer<Pointer<Utf8>>,
      ),
      Pointer<Uint64> Function(Pointer<Uint8>, int, int, Pointer<Pointer<Utf8>>)
    >('venera_saf_open');
final _retain = _library
    .lookupFunction<
      Pointer<Uint64> Function(Uint64),
      Pointer<Uint64> Function(int)
    >('venera_saf_retain');
final _close = _library
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
      int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
    >('venera_saf_close_payload');
final _read = _library
    .lookupFunction<
      Int64 Function(Uint64, Pointer<Uint8>, Size, Pointer<Int32>),
      int Function(int, Pointer<Uint8>, int, Pointer<Int32>)
    >('venera_saf_read');
final _write = _library
    .lookupFunction<
      Int64 Function(Uint64, Pointer<Uint8>, Size, Pointer<Int32>),
      int Function(int, Pointer<Uint8>, int, Pointer<Int32>)
    >('venera_saf_write');
final _value = _library
    .lookupFunction<
      Int64 Function(Uint64, Int32, Int64, Pointer<Int32>),
      int Function(int, int, int, Pointer<Int32>)
    >('venera_saf_value');
final _release = _library
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'venera_saf_release',
    );
final _free = _library
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'venera_saf_free',
    );
final _finalizer = NativeFinalizer(_library.lookup('venera_saf_release'));
final _count = _library.lookupFunction<Uint64 Function(), int Function()>(
  'venera_saf_descriptor_count',
);

/// Internal lease. A transfer holds its worker lease until the receiver has
/// retained its own lease and acknowledged it. IDs are never OS FD numbers.
final class NativeSafDescriptor implements Finalizable {
  NativeSafDescriptor._(this._pointer) {
    try {
      _finalizer.attach(this, _pointer.cast(), detach: this);
    } catch (_) {
      _finalizer.detach(this);
      _release(_pointer.cast());
      _pointer = nullptr;
      rethrow;
    }
  }
  Pointer<Uint64> _pointer;
  bool get isClosed => _pointer == nullptr;

  factory NativeSafDescriptor.retain(int token) {
    final pointer = _retain(token);
    if (pointer == nullptr) {
      throw const FileSystemException(
        'Provider descriptor transfer was cancelled',
      );
    }
    return NativeSafDescriptor._(pointer);
  }

  int get token {
    if (_pointer == nullptr) {
      throw StateError('Provider descriptor lease is closed');
    }
    return _pointer.value;
  }

  void close(String path) {
    if (isClosed) throw FileSystemException('File is closed', path);
    final error = calloc<Pointer<Utf8>>();
    final pointer = _pointer;
    _pointer = nullptr;
    _finalizer.detach(this);
    try {
      final status = _close(pointer.cast(), error);
      if (status != 0) {
        throw FileSystemException(
          error.value == nullptr
              ? 'Provider file close failed'
              : error.value.toDartString(),
          path,
        );
      }
    } finally {
      if (error.value != nullptr) _free(error.value.cast());
      calloc.free(error);
    }
  }

  void dispose() {
    if (_pointer == nullptr) return;
    final pointer = _pointer;
    _pointer = nullptr;
    _finalizer.detach(this);
    _release(pointer.cast());
  }
}

NativeSafDescriptor descriptorWorker(String path, int mode) {
  final bytes = utf8.encode(safPath(path));
  Pointer<Uint8> input = nullptr;
  Pointer<Pointer<Utf8>> error = nullptr;
  try {
    input = malloc<Uint8>(bytes.length);
    error = calloc<Pointer<Utf8>>();
    input.asTypedList(bytes.length).setAll(0, bytes);
    final pointer = _open(input, bytes.length, mode, error);
    if (pointer == nullptr) {
      throw FileSystemException(
        error.value == nullptr
            ? 'Unable to open provider file'
            : error.value.toDartString(),
        path,
      );
    }
    return NativeSafDescriptor._(pointer);
  } finally {
    if (error != nullptr && error.value != nullptr) _free(error.value.cast());
    calloc.free(error);
    malloc.free(input);
  }
}

class NativeSafBackend extends SafBackend {
  @override
  bool get runsNatively => true;

  @override
  Map<String, dynamic> invoke(Map<String, dynamic> request) {
    final bytes = utf8.encode(jsonEncode(request));
    Pointer<Uint8> input = nullptr;
    Pointer<Pointer<Uint8>> output = nullptr;
    Pointer<Size> length = nullptr;
    try {
      input = malloc<Uint8>(bytes.length);
      output = calloc<Pointer<Uint8>>();
      length = calloc<Size>();
      input.asTypedList(bytes.length).setAll(0, bytes);
      final status = _metadata(input, bytes.length, output, length);
      if (status != 0 || output.value == nullptr) {
        throw FileSystemException(
          'Native document-provider bridge is unavailable ($status)',
          request['path'] as String?,
        );
      }
      final response =
          jsonDecode(utf8.decode(output.value.asTypedList(length.value)))
              as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw FileSystemException(
          response['message'] as String? ??
              'Document-provider operation failed',
          request['path'] as String?,
          OSError(
            response['message'] as String? ?? 'Provider error',
            response['errno'] as int? ?? 5,
          ),
        );
      }
      return response['result'] as Map<String, dynamic>;
    } finally {
      if (output != nullptr && output.value != nullptr) {
        _free(output.value.cast());
      }
      calloc.free(length);
      calloc.free(output);
      malloc.free(input);
    }
  }

  @override
  Future<Map<String, dynamic>> invokeAsync(Map<String, dynamic> request) =>
      nativeTask<Map<String, dynamic>>(metadataWorker, [request]);
  @override
  Future<Uint8List> readAll(String path) =>
      nativeTask<Uint8List>(readWorker, [path]);
  @override
  Future<void> writeAll(
    String path,
    List<int> bytes,
    FileMode mode,
    bool flush,
  ) => nativeTask<void>(writeWorker, [path, bytes, safMode(mode), flush]);

  @override
  RandomAccessFile openSync(String path, FileMode mode) {
    final lease = descriptorWorker(path, safMode(mode));
    return AndroidRandomAccessFile(lease, path);
  }

  @override
  Future<RandomAccessFile> open(String path, FileMode mode) async {
    final lease = await nativeTask<NativeSafDescriptor>(descriptorWorker, [
      path,
      safMode(mode),
    ]);
    return AndroidRandomAccessFile(lease, path);
  }
}

int nativeDescriptorCount() => _count();

Never _descriptorError(int code, String path) => throw FileSystemException(
  'Document-provider file operation failed',
  path,
  OSError('Native IO error', code),
);

Uint8List descriptorReadWorker(int token, int count, String path) {
  if (count > 0x7fffffff) throw RangeError.range(count, 0, 0x7fffffff, 'count');
  Pointer<Uint8> bytes = nullptr;
  Pointer<Int32> error = nullptr;
  try {
    error = calloc<Int32>();
    if (count != 0) bytes = malloc<Uint8>(count);
    final read = _read(token, bytes, count, error);
    if (read < 0) _descriptorError(error.value, path);
    return read == 0
        ? Uint8List(0)
        : Uint8List.fromList(bytes.asTypedList(read));
  } finally {
    malloc.free(bytes);
    calloc.free(error);
  }
}

void descriptorWriteWorker(int token, Uint8List value, String path) {
  if (value.length > 0x7fffffff) {
    throw RangeError('Provider write is too large');
  }
  Pointer<Uint8> bytes = nullptr;
  Pointer<Int32> error = nullptr;
  try {
    error = calloc<Int32>();
    if (value.isNotEmpty) {
      bytes = malloc<Uint8>(value.length);
      bytes.asTypedList(value.length).setAll(0, value);
    }
    if (_write(token, bytes, value.length, error) < 0) {
      _descriptorError(error.value, path);
    }
  } finally {
    malloc.free(bytes);
    calloc.free(error);
  }
}

int descriptorValueWorker(int token, int operation, int value, String path) {
  final error = calloc<Int32>();
  try {
    final result = _value(token, operation, value, error);
    if (result < 0) _descriptorError(error.value, path);
    return result;
  } finally {
    calloc.free(error);
  }
}
