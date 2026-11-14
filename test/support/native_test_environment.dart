import 'dart:io';

/// CI prepares these libraries before running their applicable regressions.
/// A missing library must fail that run instead of turning it into a skip.
bool get requireNativeTestLibraries =>
    Platform.environment['VENERA_REQUIRE_NATIVE_TEST_LIBRARIES'] == '1';

/// Use the bundle built by the current job, including its Flutter DLLs/assets.
/// Local runs can use either a Debug or Release bundle without editing tests.
Directory get windowsNativeTestDirectory {
  if (!Platform.isWindows) {
    throw StateError('A Windows test bundle was requested on another platform');
  }
  final configured = Platform.environment['VENERA_NATIVE_TEST_DIRECTORY'];
  if (configured != null) {
    final directory = Directory(configured).absolute;
    if (configured.trim().isEmpty || !directory.existsSync()) {
      throw FileSystemException(
        'Configured native test bundle is missing',
        configured,
      );
    }
    return directory;
  }
  for (final configuration in ['Debug', 'Release']) {
    final directory = Directory(
      'build/windows/x64/runner/$configuration',
    ).absolute;
    if (File('${directory.path}/flutter_windows.dll').existsSync()) {
      return directory;
    }
  }
  throw StateError(
    'Build the Windows application or set VENERA_NATIVE_TEST_DIRECTORY '
    'to its native test bundle',
  );
}

File windowsNativeTestFile(String relativePath) {
  final file = File('${windowsNativeTestDirectory.path}/$relativePath');
  if (!file.existsSync()) {
    throw FileSystemException(
      'Required native test bundle file is missing',
      file.path,
    );
  }
  return file;
}

String get windowsNativeCodecTestLibrary {
  final configured = Platform.environment['VENERA_NATIVE_TEST_LIBRARY'];
  if (configured == null) {
    return windowsNativeTestFile('venera_native.dll').path;
  }
  final file = File(configured).absolute;
  if (configured.trim().isEmpty || !file.existsSync()) {
    throw FileSystemException(
      'Configured native codec test library is missing',
      configured,
    );
  }
  return file.path;
}
