// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_library.dart';

final _encode = nativeLibrary
    .lookupFunction<
      Uint32 Function(
        Pointer<Uint8>,
        Size,
        Uint32,
        Uint32,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>,
      ),
      int Function(
        Pointer<Uint8>,
        int,
        int,
        int,
        Pointer<Pointer<Uint8>>,
        Pointer<Size>,
      )
    >('venera_png_encode');
final _free = nativeLibrary
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'venera_native_free',
    );
final _errorText = nativeLibrary
    .lookupFunction<
      Pointer<Utf8> Function(Uint32),
      Pointer<Utf8> Function(int)
    >('venera_png_error_text');

class PngEncodingException implements Exception {
  const PngEncodingException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'PNG encoding failed ($code): $message';
}

/// Encodes straight RGBA bytes, including typed views, into owned PNG bytes.
/// Native allocations are released before returning or propagating a failure.
Uint8List encodePngRgba(Uint8List pixels, int width, int height) {
  if (width <= 0 || height <= 0 || width > 0xffffffff || height > 0xffffffff) {
    throw ArgumentError('PNG dimensions must be positive 32-bit integers');
  }
  if (width > pixels.length ~/ 4 ~/ height ||
      width * height * 4 != pixels.length) {
    throw ArgumentError('RGBA byte length must equal width * height * 4');
  }
  Pointer<Uint8> input = nullptr;
  Pointer<Pointer<Uint8>> output = nullptr;
  Pointer<Size> length = nullptr;
  try {
    input = malloc<Uint8>(pixels.length);
    input.asTypedList(pixels.length).setAll(0, pixels);
    output = calloc<Pointer<Uint8>>();
    length = calloc<Size>();
    final code = _encode(input, pixels.length, width, height, output, length);
    if (code != 0) {
      throw PngEncodingException(code, _errorText(code).toDartString());
    }
    if (output.value == nullptr || length.value == 0) {
      throw const PngEncodingException(1003, 'Native encoder returned no PNG');
    }
    return Uint8List.fromList(output.value.asTypedList(length.value));
  } finally {
    if (output != nullptr) {
      if (output.value != nullptr) _free(output.value.cast());
      calloc.free(output);
    }
    if (length != nullptr) calloc.free(length);
    if (input != nullptr) malloc.free(input);
  }
}
