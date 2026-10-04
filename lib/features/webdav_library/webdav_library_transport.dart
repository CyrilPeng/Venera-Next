import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:venera_next/network/app_dio.dart' show RHttpAdapter;
import 'package:webdav_client/webdav_client.dart' hide File;
import 'webdav_library_config.dart';
import 'webdav_library_entries.dart';

abstract class WebDavLibraryOps {
  /// Cancel accepted requests without preventing later requests after a resume.
  void cancelPending() {}

  void dispose() {}

  /// Join transport work that may outlive a client's cancellation result.
  Future<void> drainPending() async {}

  Future<void> test(WebDavLibraryConfig config);

  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  );

  Future<String> readText(WebDavLibraryConfig config, String remotePath);
}

class WebDavHttpLibraryOps extends WebDavLibraryOps {
  WebDavHttpLibraryOps({Client Function(WebDavLibraryConfig)? createClient})
    : _createClient =
          createClient ?? ((config) => config.endpoint.createClient());

  final Client Function(WebDavLibraryConfig) _createClient;
  final _clients = <String, Client>{};
  final _pending = <CancelToken>{};
  final _nativeAdapters = Set<RHttpAdapter>.identity();
  bool _disposed = false;

  @override
  void cancelPending() {
    for (final token in _pending.toList()) {
      token.cancel('WebDAV library request cancelled');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final clients = _clients.values.toList();
    _clients.clear();
    final failures = <({Object error, StackTrace stack})>[];
    void release(void Function() action) {
      try {
        action();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }

    // Tokens stop active SDK calls; force-closing adapters also cancels native
    // work that has outlived an SDK result. drainPending joins native completion
    // and upload/response cleanup before the source can release its resources.
    release(cancelPending);
    for (final client in clients) {
      release(() => client.c.close(force: true));
    }
    if (failures.isNotEmpty) throw WebDavTransportCloseFailure(failures);
  }

  Client _client(WebDavLibraryConfig config) {
    return _clients.putIfAbsent(config.connectionKey, () {
      final client = _createClient(config);
      final adapter = client.c.httpClientAdapter;
      if (adapter is RHttpAdapter) _nativeAdapters.add(adapter);
      return client;
    });
  }

  @override
  Future<void> drainPending() async {
    final failures = <({Object error, StackTrace stack})>[];
    final adapters = _nativeAdapters.toList();
    await Future.wait([
      for (final adapter in adapters)
        Future<void>.sync(() async {
          try {
            await adapter.waitForIdle();
          } catch (error, stack) {
            failures.add((error: error, stack: stack));
          }
        }),
    ]);
    if (failures.isNotEmpty) throw WebDavTransportCloseFailure(failures);
    if (_disposed) _nativeAdapters.clear();
  }

  Future<T> _request<T>(
    WebDavLibraryConfig config,
    Future<T> Function(Client client, CancelToken token) run,
  ) {
    if (_disposed) {
      return Future.error(StateError('WebDAV transport is disposed'));
    }
    final token = CancelToken();
    _pending.add(token);
    return Future<T>.sync(
      () => run(_client(config), token),
    ).whenComplete(() => _pending.remove(token));
  }

  @override
  Future<void> test(WebDavLibraryConfig config) =>
      _request(config, (client, token) async {
        await client.readDir(config.remotePath, token);
      });

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) => _request(config, (client, token) async {
    final entries = await client.readDir(remotePath, token);
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
  });

  @override
  Future<String> readText(WebDavLibraryConfig config, String remotePath) =>
      _request(config, (client, token) async {
        final bytes = await client.read(remotePath, cancelToken: token);
        return utf8.decode(bytes, allowMalformed: false);
      });
}

class WebDavTransportCloseFailure implements Exception {
  WebDavTransportCloseFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'WebDAV transport cleanup failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
}
