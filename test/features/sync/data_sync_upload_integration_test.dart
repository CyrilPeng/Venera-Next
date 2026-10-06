import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  test(
    'real upload clears its durable marker before acknowledging the terminal receipt',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final day =
          fixture.now.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
      for (var offset = 1; offset <= 9; offset++) {
        fixture.server.store(
          '${day - offset}-7.venera',
          utf8.encode('old archive $offset'),
        );
      }
      final today = '$day-6.venera';
      final oldest = '${day - 9}-7.venera';
      fixture.server.store(
        today,
        utf8.encode('same day archive from another device'),
      );

      final result = await fixture.controller.uploadData();
      expect(result.success, isTrue);
      expect(fixture.prepareCalls, 1);
      expect(fixture.exports, 1);
      expect(fixture.timeWrites, 1);
      expect(fixture.settings['dataVersion'], 8);
      expect(fixture.controller.hasPendingChanges, isFalse);
      final puts = fixture.server.byMethod('PUT');
      expect(puts, hasLength(1));
      final name = puts.single.name;
      expect(name, startsWith('$day-8-'));
      expect(puts.single.ifNoneMatch, '*');
      expect(fixture.server.files[name]!.bytes, fixture.exportedBytes);
      expect(
        fixture.server.byMethod('DELETE').map((r) => r.name),
        unorderedEquals([today, oldest]),
      );
      expect(
        fixture.server.byMethod('DELETE').every((r) => r.ifMatch != null),
        isTrue,
      );
      expect(fixture.server.files, hasLength(9));
      expect(fixture.markerClearedWithTerminalReceipt, isTrue);
      expect(fixture.lastTerminal?.phase, 'finished');
      expect(fixture.lastTerminal?.commitState, DataSyncCommitState.applied);
      expect(fixture.durableImplicit['webdavSyncOperation'], isNull);
      expect(fixture.records, isEmpty);
      expect(
        Directory(p.dirname(fixture.destinations.single)).existsSync(),
        isFalse,
      );
      expect(fixture.server.errors, isEmpty);
    },
  );

  test(
    'saved PUT with a lost response recovers through a rebuilt controller without another export or PUT',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      fixture.server.loseNextPutResponse = true;
      final first = await fixture.controller.uploadData();
      expect(first.error, isTrue);
      expect(
        (first.failure as DataSyncFailure).commitState,
        DataSyncCommitState.recoveryRequired,
      );
      final before = fixture.records.single;
      expect(before.phase, 'putPending');
      expect(before.sourceCleaned, isFalse);
      final marker = DataSyncOperation.fromJson(
        fixture.durableImplicit['webdavSyncOperation'],
      );
      expect(marker.id, before.operationId);
      expect(marker.version, 3);
      expect(marker.commitState, DataSyncCommitState.recoveryRequired);
      expect(
        fixture.server.files[before.remoteName]!.bytes,
        fixture.exportedBytes,
      );
      expect(File(fixture.destinations.single).existsSync(), isTrue);
      expect(fixture.timeWrites, 0);

      await fixture.rebuild();
      final recovered = await fixture.controller.downloadData();
      expect(recovered.success, isTrue);
      expect(fixture.controllersCreated, 2);
      expect(fixture.transfersCreated, 2);
      expect(fixture.prepareCalls, 1);
      expect(fixture.exports, 1);
      expect(fixture.settings['dataVersion'], 8);
      expect(fixture.timeWrites, 1);
      expect(fixture.server.byMethod('PUT'), hasLength(1));
      expect(fixture.server.byMethod('PROPFIND'), hasLength(1));
      expect(
        fixture.server
            .byMethod('GET')
            .where((r) => r.name == before.remoteName),
        hasLength(2),
      );
      expect(fixture.markerClearedWithTerminalReceipt, isTrue);
      expect(fixture.lastTerminal?.operationId, before.operationId);
      expect(fixture.durableImplicit['webdavSyncOperation'], isNull);
      expect(fixture.controller.hasPendingChanges, isTrue);
      expect(fixture.records, isEmpty);
      expect(File(fixture.destinations.single).existsSync(), isFalse);
      expect(fixture.server.errors, isEmpty);
    },
  );

  test(
    'rebuilt upload recovery refuses different content at its original remote name',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      fixture.server.loseNextPutResponse = true;
      expect((await fixture.controller.uploadData()).error, isTrue);
      final before = fixture.records.single;
      final replacement = Uint8List.fromList(
        utf8.encode('concurrent remote replacement'),
      );
      fixture.server.store(before.remoteName!, replacement);

      await fixture.rebuild();
      final result = await fixture.controller.uploadData();
      expect(result.error, isTrue);
      expect(
        (result.failure as DataSyncFailure).commitState,
        DataSyncCommitState.recoveryRequired,
      );
      expect(fixture.server.files[before.remoteName]!.bytes, replacement);
      expect(fixture.server.byMethod('PUT'), hasLength(1));
      expect(fixture.server.byMethod('DELETE'), isEmpty);
      expect(fixture.prepareCalls, 1);
      expect(fixture.exports, 1);
      expect(fixture.timeWrites, 0);
      final retained = fixture.records.single;
      expect(retained.operationId, before.operationId);
      expect(retained.phase, 'putPending');
      expect(
        retained.sha256,
        sha256.convert(fixture.exportedBytes!).toString(),
      );
      expect(
        File(fixture.destinations.single).readAsBytesSync(),
        fixture.exportedBytes,
      );
      final marker = DataSyncOperation.fromJson(
        fixture.durableImplicit['webdavSyncOperation'],
      );
      expect(marker.id, before.operationId);
      expect(marker.commitState, DataSyncCommitState.recoveryRequired);
      expect(marker.followUpComplete, isFalse);
      expect(fixture.markerClearedWithTerminalReceipt, isFalse);
      fixture.expectUnresolvedRecoveryOnClose = true;
      expect(fixture.server.errors, isEmpty);
    },
  );
}

class _Fixture {
  _Fixture(this.root, this.server);
  final Directory root;
  final _WebDavServer server;
  final now = DateTime.utc(2026, 10, 5, 12);
  late Map<String, dynamic> settings;
  late Map<String, dynamic> implicit;
  DataSyncController? _controller;
  int controllersCreated = 0;
  int transfersCreated = 0;
  int prepareCalls = 0;
  int exports = 0;
  int timeWrites = 0;
  Uint8List? exportedBytes;
  final destinations = <String>[];
  bool markerClearedWithTerminalReceipt = false;
  DataSyncUploadRecord? lastTerminal;
  bool expectUnresolvedRecoveryOnClose = false;

  String get dataPath => p.join(root.path, 'data');
  File get settingsFile => File(p.join(root.path, 'settings.json'));
  File get implicitFile => File(p.join(root.path, 'implicit.json'));
  Map<String, dynamic> get durableImplicit =>
      jsonDecode(implicitFile.readAsStringSync()) as Map<String, dynamic>;

  static Future<_Fixture> create() async {
    final server = await _WebDavServer.start();
    final root = Directory.systemTemp.createTempSync('upload-integration-');
    final fixture = _Fixture(root, server);
    Directory(fixture.dataPath).createSync();
    fixture.settings = {
      'webdav': [server.url, '', ''],
      'disableSyncFields': '',
      'dataVersion': 7,
      'lastSyncTime': 0,
    };
    fixture.implicit = {'webdavSyncMode': 'manual', 'webdavSyncPending': true};
    await fixture.saveSettings();
    await fixture.persistImplicit();
    return fixture;
  }

  List<DataSyncUploadRecord> get records {
    final journal = DataSyncUploadJournal.open(dataPath);
    try {
      return journal.records;
    } finally {
      journal.close();
    }
  }

  Future<void> saveSettings() =>
      settingsFile.writeAsString(jsonEncode(settings), flush: true);

  Future<void> persistImplicit() async {
    await implicitFile.writeAsString(jsonEncode(implicit), flush: true);
    if (implicit['webdavSyncOperation'] == null) {
      final terminals = records.where((record) => record.isTerminal).toList();
      if (terminals.isNotEmpty) {
        markerClearedWithTerminalReceipt = true;
        lastTerminal = terminals.single;
      }
    }
  }

  DataSyncController get controller {
    if (_controller case final existing?) return existing;
    final participant = _Participant(this);
    final transfer = WebDavDataSyncTransfer(
      participant: participant,
      openRemote: (connection) => WebDavDataSyncRemote(
        connection,
        createClient: (endpoint) =>
            endpoint.createClient(adapter: IOHttpClientAdapter()),
      ),
      uploadJournalPath: () => dataPath,
      now: () => now,
    );
    transfersCreated++;
    controllersCreated++;
    return _controller = DataSyncController(
      preferences: SyncPreferenceStore(
        readSetting: (key) => settings[key],
        writeSetting: (key, value) => settings[key] = value,
        implicitData: () => implicit,
      ),
      transfer: () => transfer,
      uploadRecovery: transfer,
      saveSettings: saveSettings,
      persistImplicit: persistImplicit,
      observeChanges: (_) => () {},
      now: () => now,
    );
  }

  Future<void> rebuild() async {
    _controller?.dispose();
    await _controller?.flushPersistence();
    _controller = null;
    settings =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    implicit = durableImplicit;
  }

  Future<void> close() async {
    try {
      _controller?.dispose();
      if (expectUnresolvedRecoveryOnClose) {
        await expectLater(
          _controller!.flushPersistence(),
          throwsA(
            isA<DataSyncFailure>().having(
              (failure) => failure.commitState,
              'unresolved outcome',
              DataSyncCommitState.recoveryRequired,
            ),
          ),
        );
      } else {
        await _controller?.flushPersistence();
      }
    } finally {
      await server.close();
      root.deleteSync(recursive: true);
    }
  }
}

class _Participant implements DataSyncParticipant {
  _Participant(this.fixture);
  final _Fixture fixture;

  @override
  String get cachePath => fixture.root.path;
  @override
  int? get version => fixture.settings['dataVersion'] as int;
  @override
  Future<int> prepareUploadVersion() async {
    fixture.prepareCalls++;
    fixture.settings['dataVersion'] = version! + 1;
    await fixture.saveSettings();
    return version!;
  }

  @override
  Future<void> exportData(
    bool excludeFields,
    File destination, {
    String? syncOperationId,
  }) async {
    fixture.exports++;
    fixture.destinations.add(destination.path);
    expect(p.basename(destination.path), 'snapshot.venera');
    expect(p.isWithin(fixture.dataPath, destination.path), isTrue);
    expect(
      p.basename(destination.parent.path),
      startsWith('.data-sync-upload-'),
    );
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': version,
          'snapshot': List.generate(2048, (i) => i % 251),
        }),
      ),
    );
    fixture.exportedBytes = bytes;
    await destination.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async {
    fixture.timeWrites++;
    fixture.settings['lastSyncTime'] = milliseconds;
    await fixture.saveSettings();
  }

  @override
  Future<DataSyncCommitState> importData(
    File file, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) => throw StateError('Recovery must not begin a download/import');
  @override
  void notifyImported() => throw StateError('Upload cannot publish an import');
}

typedef _Request = ({
  String method,
  String name,
  String? ifNoneMatch,
  String? ifMatch,
});
typedef _Stored = ({Uint8List bytes, String etag});

class _WebDavServer {
  _WebDavServer(this.server);
  final HttpServer server;
  final files = <String, _Stored>{};
  final requests = <_Request>[];
  final errors = <Object>[];
  bool loseNextPutResponse = false;
  var _revision = 0;
  static const path = '/dav/MixedRoot/';

  String get url =>
      'http://127.0.0.1:${server.port}${path.substring(0, path.length - 1)}';
  List<_Request> byMethod(String method) =>
      requests.where((request) => request.method == method).toList();

  static Future<_WebDavServer> start() async {
    final fixture = _WebDavServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  void store(String name, List<int> bytes) => files[name] = (
    bytes: Uint8List.fromList(bytes),
    etag: '"revision-${++_revision}"',
  );

  Future<void> _handle(HttpRequest request) async {
    var detached = false;
    try {
      final name = request.uri.path.startsWith(path)
          ? request.uri.path.substring(path.length)
          : 'invalid-root';
      requests.add((
        method: request.method,
        name: name,
        ifNoneMatch: request.headers.value(HttpHeaders.ifNoneMatchHeader),
        ifMatch: request.headers.value(HttpHeaders.ifMatchHeader),
      ));
      final body = await request.fold<BytesBuilder>(
        BytesBuilder(),
        (all, chunk) => all..add(chunk),
      );
      switch (request.method) {
        case 'PROPFIND':
          if (name.isNotEmpty) throw StateError('Wrong listing root');
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write(_listing());
        case 'GET':
          final entry = files[name];
          if (entry == null) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.headers.set(HttpHeaders.etagHeader, entry.etag);
            request.response.contentLength = entry.bytes.length;
            request.response.add(entry.bytes);
          }
        case 'PUT':
          if (request.headers.value(HttpHeaders.ifNoneMatchHeader) != '*') {
            throw StateError('Unconditional PUT is forbidden');
          }
          if (files.containsKey(name)) {
            request.response.statusCode = HttpStatus.preconditionFailed;
          } else {
            store(name, body.takeBytes());
            if (loseNextPutResponse) {
              loseNextPutResponse = false;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              detached = true;
              socket.destroy();
            } else {
              request.response.statusCode = HttpStatus.created;
            }
          }
        case 'DELETE':
          final condition = request.headers.value(HttpHeaders.ifMatchHeader);
          if (condition == null || condition == '*') {
            throw StateError('Unconditional DELETE is forbidden');
          }
          final entry = files[name];
          if (entry == null) {
            request.response.statusCode = HttpStatus.notFound;
          } else if (condition != entry.etag) {
            request.response.statusCode = HttpStatus.preconditionFailed;
          } else {
            files.remove(name);
            request.response.statusCode = HttpStatus.noContent;
          }
        default:
          throw StateError('Unexpected HTTP ${request.method}');
      }
    } catch (error) {
      errors.add(error);
      if (!detached) {
        request.response.statusCode = HttpStatus.internalServerError;
      }
    } finally {
      if (!detached) await request.response.close();
    }
  }

  String _listing() =>
      '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>$path</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
${files.entries.map((entry) => '<D:response><D:href>$path${entry.key}</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>${entry.value.bytes.length}</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>').join()}
</D:multistatus>''';

  Future<void> close() => server.close(force: true);
}
