import 'dart:convert';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'webdav_library_config.dart';
import 'webdav_library_entries.dart';

abstract class WebDavLibraryOps {
  void dispose() {}

  Future<void> test(WebDavLibraryConfig config);

  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  );

  Future<String> readText(WebDavLibraryConfig config, String remotePath);
}

class WebDavHttpLibraryOps extends WebDavLibraryOps {
  @override
  void dispose() {
    for (final client in _clients.values) {
      client.c.close(force: true);
    }
    _clients.clear();
  }

  final _clients = <String, Client>{};

  Client _client(WebDavLibraryConfig config) {
    return _clients.putIfAbsent(
      config.connectionKey,
      config.endpoint.createClient,
    );
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    final entries = await _client(config).readDir(remotePath);
    return entries
        .where((entry) => entry.name != null)
        .map(
          (entry) => WebDavLibraryEntry(
            name: entry.name!,
            isDirectory: entry.isDir == true,
            eTag: entry.eTag?.isEmpty == true ? null : entry.eTag,
            modifiedAt: entry.mTime?.millisecondsSinceEpoch,
          ),
        )
        .toList();
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String remotePath) async {
    final bytes = await _client(config).read(remotePath);
    return utf8.decode(bytes, allowMalformed: false);
  }
}
