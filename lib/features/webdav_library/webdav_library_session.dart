import 'webdav_library_config.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_transport.dart';

class WebDavLibraryCancelled implements Exception {
  const WebDavLibraryCancelled();

  @override
  String toString() => 'WebDAV request cancelled';
}

/// Each asynchronous operation retains this session, never the next config.
class WebDavLibrarySession {
  WebDavLibrarySession(this.config, this.ops, {required this.isCurrent});

  final WebDavLibraryConfig config;
  final WebDavLibraryOps ops;
  final bool Function() isCurrent;
  bool _cancelled = false;
  bool get isActive => !_cancelled && isCurrent();

  void cancel() => _cancelled = true;

  void check() {
    if (!isActive) throw const WebDavLibraryCancelled();
  }

  Future<List<WebDavLibraryEntry>> readDir(String path) async {
    check();
    final entries = await ops.readDir(config, path);
    check();
    return entries;
  }

  Future<String> readText(String path) async {
    check();
    final text = await ops.readText(config, path);
    check();
    return text;
  }
}
