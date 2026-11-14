import 'package:sqlite3/sqlite3.dart';
import 'native_test_environment.dart';

bool sqliteTestAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    if (requireNativeTestLibraries) rethrow;
    return false;
  }
}
