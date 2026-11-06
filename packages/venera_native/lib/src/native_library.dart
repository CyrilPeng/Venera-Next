// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

import 'dart:ffi';
import 'dart:io';

final DynamicLibrary nativeLibrary = switch (Platform.operatingSystem) {
  'windows' => DynamicLibrary.open('venera_native.dll'),
  'android' || 'linux' || 'ohos' => DynamicLibrary.open('libvenera_native.so'),
  'ios' ||
  'macos' => DynamicLibrary.open('venera_native.framework/venera_native'),
  _ => throw UnsupportedError(
    'Native codecs are unavailable on ${Platform.operatingSystem}',
  ),
};
