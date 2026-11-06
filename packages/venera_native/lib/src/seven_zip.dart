// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import 'native_library.dart';

final _open = nativeLibrary
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Uint32>),
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Uint32>)
    >('venera_7z_open');
final _close = nativeLibrary
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'venera_7z_close',
    );
final _count = nativeLibrary
    .lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('venera_7z_count');
final _name = nativeLibrary
    .lookupFunction<
      Size Function(Pointer<Void>, Uint32, Pointer<Uint16>, Size),
      int Function(Pointer<Void>, int, Pointer<Uint16>, int)
    >('venera_7z_name');
final _kind = nativeLibrary
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('venera_7z_kind');
final _read = nativeLibrary
    .lookupFunction<
      Uint32 Function(
        Pointer<Void>,
        Uint32,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>,
      ),
      int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>, Pointer<Size>)
    >('venera_7z_read');

class SevenZipException implements Exception {
  const SevenZipException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      '7z extraction failed${code == null ? '' : ' ($code)'}: $message';
}

/// A worker owns one decoder and reuses its solid-block cache. No native handle
/// or borrowed native bytes cross isolate boundaries or escape this operation.
Future<void> extractSevenZip(String archivePath, String outputPath) =>
    Isolate.run(() => _extract(archivePath, outputPath));

void _extract(String archivePath, String outputPath) {
  if (archivePath.contains('\u0000')) {
    throw ArgumentError('Archive path contains a null character');
  }
  final input = archivePath.toNativeUtf8();
  Pointer<Uint32> status = nullptr;
  Pointer<Void> archive = nullptr;
  try {
    status = calloc<Uint32>();
    archive = _open(input, status);
    if (archive == nullptr) {
      throw SevenZipException('Cannot open the archive', code: status.value);
    }
    final root = path.normalize(path.absolute(outputPath));
    if (FileSystemEntity.typeSync(root, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SevenZipException('Output directory is a symbolic link');
    }
    Directory(root).createSync(recursive: true);
    final entries = <({int index, String destination, bool directory})>[];
    final kinds = <String, bool>{};
    // Inspect every name and kind before writing the first file.
    for (var index = 0; index < _count(archive); index++) {
      final kind = _kind(archive, index);
      if (kind < 0 || kind == 2) {
        throw const SevenZipException('Invalid or symbolic-link archive entry');
      }
      final units = _name(archive, index, nullptr, 0);
      if (units <= 1 || units > 32768) {
        throw const SevenZipException('Invalid archive filename length');
      }
      final buffer = calloc<Uint16>(units);
      String name;
      try {
        if (_name(archive, index, buffer, units) != units) {
          throw const SevenZipException('Cannot read the archive filename');
        }
        name = buffer.cast<Utf16>().toDartString(length: units - 1);
      } finally {
        calloc.free(buffer);
      }
      final relative = _relativeName(name);
      final destination = path.join(root, relative);
      if (!path.isWithin(root, destination)) {
        throw const SevenZipException(
          'Archive path escapes the output directory',
        );
      }
      final key = _pathKey(destination);
      if (kinds.containsKey(key)) {
        throw const SevenZipException('Archive contains conflicting filenames');
      }
      kinds[key] = kind == 1;
      entries.add((
        index: index,
        destination: destination,
        directory: kind == 1,
      ));
    }
    for (final entry in entries) {
      var parent = path.dirname(entry.destination);
      while (path.isWithin(root, parent)) {
        if (kinds[_pathKey(parent)] == false) {
          throw const SevenZipException(
            'Archive file occupies a parent directory',
          );
        }
        parent = path.dirname(parent);
      }
    }
    Pointer<Pointer<Uint8>> bytes = nullptr;
    Pointer<Size> length = nullptr;
    try {
      bytes = calloc<Pointer<Uint8>>();
      length = calloc<Size>();
      for (final entry in entries) {
        _checkExistingParents(root, entry.destination);
        if (entry.directory) {
          Directory(entry.destination).createSync(recursive: true);
          continue;
        }
        final code = _read(archive, entry.index, bytes, length);
        if (code != 0) {
          throw SevenZipException(
            'Cannot decode or verify archive data',
            code: code,
          );
        }
        if (length.value > 0 && bytes.value == nullptr) {
          throw const SevenZipException(
            'Decoder returned an invalid byte buffer',
          );
        }
        final destination = File(entry.destination);
        destination.parent.createSync(recursive: true);
        final file = destination.openSync(mode: FileMode.write);
        try {
          if (length.value != 0) {
            // This view remains valid until the next decoder call or close.
            file.writeFromSync(bytes.value.asTypedList(length.value));
          }
        } finally {
          file.closeSync();
        }
      }
    } finally {
      if (bytes != nullptr) calloc.free(bytes);
      if (length != nullptr) calloc.free(length);
    }
  } finally {
    if (archive != nullptr) _close(archive);
    malloc.free(input);
    if (status != nullptr) calloc.free(status);
  }
}

String _pathKey(String value) =>
    Platform.isWindows || Platform.isMacOS ? value.toLowerCase() : value;

String _relativeName(String name) {
  final normalized = name.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      normalized.contains('\u0000')) {
    throw const SevenZipException(
      'Archive filename is absolute or contains null',
    );
  }
  final parts = normalized
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.isEmpty ||
      parts.any(
        (part) => part == '..' || Platform.isWindows && part.contains(':'),
      )) {
    throw const SevenZipException('Archive filename contains an unsafe path');
  }
  if (Platform.isWindows &&
      parts.any(
        (part) =>
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(
              r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw const SevenZipException(
      'Archive filename conflicts with a Windows path',
    );
  }
  return path.joinAll(parts);
}

void _checkExistingParents(String root, String destination) {
  var current = destination;
  while (current == root || path.isWithin(root, current)) {
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (current != destination && type == FileSystemEntityType.file)) {
      throw const SevenZipException(
        'Existing output path is a link or a file parent',
      );
    }
    if (current == root) break;
    current = path.dirname(current);
  }
}
