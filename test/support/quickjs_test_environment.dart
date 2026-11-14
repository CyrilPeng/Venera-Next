import 'dart:ffi';
import 'dart:io';
import 'native_test_environment.dart';

bool quickJsTestAvailable() {
  try {
    if (Platform.isWindows) {
      final directory = windowsNativeTestDirectory.path;
      DynamicLibrary.open('$directory/flutter_windows.dll');
      DynamicLibrary.open('$directory/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
    return true;
  } catch (_) {
    if (requireNativeTestLibraries) rethrow;
    return false;
  }
}
