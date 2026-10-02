import 'dart:typed_data';
import 'package:webdav_client/webdav_client.dart';
import 'package:venera_next/network/webdav.dart';
import 'data_sync_transfer.dart';

class WebDavDataSyncRemote implements DataSyncRemote {
  WebDavDataSyncRemote(WebDavEndpoint connection)
    : _client = connection.createClient(logRequests: true);

  final Client _client;

  @override
  Future<List<String>> listNames() async => [
    for (final entry in await _client.readDir('/'))
      if (entry.name != null) entry.name!,
  ];

  @override
  Future<void> remove(String name) => _client.remove(name);

  @override
  Future<void> write(String name, Uint8List bytes) =>
      _client.write(name, bytes);

  @override
  Future<void> readToFile(String name, String path) =>
      _client.read2File(name, path);

  @override
  void dispose() => _client.c.close(force: true);
}
