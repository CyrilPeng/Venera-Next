// A real Dart VM executing the production upload journal and executor. The
// parent owns the HTTP peer and may kill this process before a response arrives.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_remote_port.dart';
import 'package:venera_next/features/sync/data_sync_upload_executor.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';
import 'package:venera_next/network/request_scope.dart';

const uploadOperationId = '4a112222-3333-4444-8555-666666666666';

Future<void> main(List<String> args) async {
  final root = p.normalize(p.absolute(args[0]));
  final endpoint = Uri.parse(args[1]);
  final command = args[2];
  final crashAt = args[3];
  if (!['upload', 'recover', 'acknowledge'].contains(command)) {
    throw ArgumentError('Unknown upload probe command');
  }
  void rendezvous(String phase) {
    if (phase != crashAt) return;
    final marker = File(p.join(root, 'ready.tmp'));
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': phase}),
      flush: true,
    );
    marker.renameSync(p.join(root, 'ready.json'));
    stdin.readLineSync();
    throw StateError('Probe resumed instead of being terminated');
  }

  void recordCall(String name) => File(
    p.join(root, '$name.calls'),
  ).writeAsStringSync('$name\n', mode: FileMode.append, flush: true);

  final journal = DataSyncUploadJournal.open(p.join(root, 'data'));
  final scope = RequestScope();
  try {
    final executor = DataSyncUploadExecutor(
      journal: journal,
      endpointFingerprint: crypto.sha256
          .convert(utf8.encode(endpoint.toString()))
          .toString(),
      openRemote: () => _HttpRemote(endpoint),
      prepareVersion: () async {
        recordCall('version');
        return 8;
      },
      exportData: (destination) async {
        recordCall('export');
        await File(p.join(root, 'incoming.venera')).copy(destination.path);
      },
      recordSyncTime: (time) async => File(
        p.join(root, 'sync-time'),
      ).writeAsStringSync('$time', flush: true),
      now: () => DateTime.utc(2026, 10, 5, 12),
      observer: (event) => rendezvous(event.phase),
    );
    DataSyncCommitState? state;
    Object? failure;
    try {
      if (command == 'acknowledge') {
        await journal.acknowledge(uploadOperationId);
      } else {
        state = command == 'upload'
            ? await executor.upload(uploadOperationId, scope)
            : await executor.recover(uploadOperationId, scope);
      }
    } on DataSyncFailure catch (error) {
      state = error.commitState;
      failure = error;
    }
    final record = journal.lookup(uploadOperationId);
    stdout.writeln(
      jsonEncode({
        'state': state?.name,
        'failure': failure?.toString(),
        'record': record == null
            ? null
            : {
                'remoteName': record.remoteName,
                'sha256': record.sha256,
                'length': record.length,
                'version': record.version,
                'committedAt': record.committedAt,
                'terminal': record.isTerminal,
                'state': record.commitState.name,
              },
      }),
    );
  } finally {
    scope.dispose();
    journal.close();
  }
}

// The remote port is independently covered by real WebDAV tests. This adapter
// gives the production executor an HTTP peer in a standalone Dart process.
class _HttpRemote implements DataSyncRemote {
  _HttpRemote(this.endpoint);
  final Uri endpoint;
  final _client = HttpClient()..findProxy = (_) => 'DIRECT';

  Future<HttpClientResponse> _request(String method, String name) async {
    final request = await _client.openUrl(method, endpoint.resolve(name));
    request.followRedirects = false;
    return request.close();
  }

  @override
  Future<List<String>> listNames() async {
    final response = await _request('GET', '');
    if (response.statusCode != 200) throw HttpException('list failed');
    return (jsonDecode(await utf8.decoder.bind(response).join()) as List)
        .cast<String>();
  }

  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) async {
    final response = await _request('GET', name);
    if (response.statusCode == 404) {
      await response.drain<void>();
      return const DataSyncArchiveMissing();
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('probe status ${response.statusCode}');
    }
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    if (response.contentLength >= 0 && bytes.length != response.contentLength) {
      throw const HttpException('truncated archive');
    }
    final tag = response.headers.value(HttpHeaders.etagHeader);
    return DataSyncArchivePresent(
      sha256: crypto.sha256.convert(bytes).toString(),
      length: bytes.length,
      strongEtag: tag != null && !tag.startsWith('W/') ? tag : null,
    );
  }

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    final bytes = await source.readAsBytes();
    if (bytes.length != length ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw StateError('Snapshot changed');
    }
    final request = await _client.putUrl(endpoint.resolve(name));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode == 412) {
      return DataSyncArchiveCreateResult.preconditionFailed;
    }
    if (response.statusCode != 201) throw HttpException('create failed');
    return DataSyncArchiveCreateResult.created;
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    final request = await _client.deleteUrl(endpoint.resolve(name));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.ifMatchHeader, strongEtag);
    final response = await request.close();
    await response.drain<void>();
    return switch (response.statusCode) {
      204 => DataSyncArchiveRemoveResult.removed,
      404 => DataSyncArchiveRemoveResult.missing,
      412 => DataSyncArchiveRemoveResult.preconditionFailed,
      _ => throw HttpException('delete failed'),
    };
  }

  @override
  Future<void> readToFile(String name, String path) =>
      throw UnsupportedError('Upload probe never downloads');

  @override
  Future<void> dispose() async => _client.close(force: true);
}
