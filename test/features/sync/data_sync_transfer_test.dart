import 'dart:async';
import 'package:venera_next/network/request_scope.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  late Directory directory;
  late RequestScope scope;
  late _Participant participant;
  late _Remote remote;
  late WebDavDataSyncTransfer transfer;
  final connection = WebDavEndpoint(
    url: 'https://example.com',
    user: '',
    password: '',
  );
  setUp(() {
    scope = RequestScope();
    directory = Directory.systemTemp.createTempSync('data-transfer-');
    participant = _Participant(directory.path);
    remote = _Remote();
    transfer = WebDavDataSyncTransfer(
      participant: participant,
      openRemote: (_) => remote,
      now: () => DateTime.fromMillisecondsSinceEpoch(20 * 86400000),
    );
  });
  tearDown(() {
    scope.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'cancelled download closes the remote and never imports late bytes',
    () async {
      remote.names = ['20-8.venera'];
      final gate = Completer<void>();
      remote.readGate = gate.future;
      final downloading = transfer.download(connection, scope: scope);
      final checked = expectLater(
        downloading,
        throwsA(isA<RequestCancelled>()),
      );
      await remote.readStarted.future;
      expect(remote.readPath, isNotNull);
      scope.cancel();
      await pumpEventQueue();
      expect(remote.closed, isTrue);
      gate.complete();
      await checked;
      expect(participant.imports, 0);
      expect(participant.notifications, 0);
      expect(participant.syncTime, isNull);
      expect(directory.listSync(), isEmpty);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'cancelled upload cannot delete or write after a delayed listing',
    () async {
      remote.names = ['20-7.venera'];
      final gate = Completer<void>();
      remote.listGate = gate.future;
      final uploading = transfer.upload(
        connection,
        excludeFields: false,
        scope: scope,
      );
      final checked = expectLater(uploading, throwsA(isA<RequestCancelled>()));
      await remote.listStarted.future;
      scope.cancel();
      gate.complete();
      await checked;
      expect(remote.removed, isEmpty);
      expect(remote.written, isNull);
      expect(participant.syncTime, isNull);
      expect(directory.listSync(), isEmpty);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'an import past its commit boundary completes notifications after cancellation',
    () async {
      remote.names = ['20-8.venera'];
      final gate = Completer<void>();
      participant.importGate = gate.future;
      final downloading = transfer.download(connection, scope: scope);
      await participant.importStarted.future;
      expect(participant.imports, 1);
      scope.cancel();
      gate.complete();
      expect(await downloading, isTrue);
      expect(participant.notifications, 1);
      expect(participant.syncTime, isNotNull);
      expect(directory.listSync(), isEmpty);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'upload preserves archive naming, exclusion and retention protocol',
    () async {
      remote.names = ['19-4.venera', '20-5.venera', 'notes.txt'];
      await transfer.upload(connection, excludeFields: true, scope: scope);
      expect(participant.version, 8);
      expect(participant.excludeFields, isTrue);
      expect(remote.removed, ['20-5.venera']);
      expect(remote.written, '20-8.venera');
      expect(remote.bytes, [1, 2, 3]);
      expect(participant.syncTime, 20 * 86400000);
      expect(directory.listSync(), isEmpty);
      expect(remote.closed, isTrue);
    },
  );

  test('failed upload releases exported archive and remote', () async {
    remote.writeError = StateError('denied');
    await expectLater(
      transfer.upload(connection, excludeFields: false, scope: scope),
      throwsStateError,
    );
    expect(participant.syncTime, isNull);
    expect(directory.listSync(), isEmpty);
    expect(remote.closed, isTrue);
  });

  test(
    'unchanged remote version does not download or clear pending via apply result',
    () async {
      remote.names = ['20-7.venera'];
      expect(await transfer.download(connection, scope: scope), isFalse);
      expect(remote.readPath, isNull);
      expect(participant.imports, 0);
      expect(participant.notifications, 0);
      expect(participant.syncTime, isNull);
      expect(remote.closed, isTrue);
    },
  );

  test('import no-op is distinct from an applied snapshot', () async {
    remote.names = ['20-8.venera'];
    participant.applied = false;
    expect(await transfer.download(connection, scope: scope), isFalse);
    expect(participant.imports, 1);
    expect(participant.notifications, 0);
    expect(participant.syncTime, isNull);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'applied snapshot notifies only after import and uses isolated local path',
    () async {
      remote.names = ['../20-8.venera'];
      expect(await transfer.download(connection, scope: scope), isTrue);
      expect(participant.imports, 1);
      expect(participant.notifications, 1);
      expect(
        remote.readPath,
        startsWith('${directory.path}${Platform.pathSeparator}data-sync-'),
      );
      expect(remote.readPath, endsWith('snapshot.venera'));
      expect(participant.syncTime, 20 * 86400000);
      expect(directory.listSync(), isEmpty);
      expect(remote.closed, isTrue);
    },
  );

  test(
    'failed import cleans downloaded bytes without success notification',
    () async {
      remote.names = ['20-8.venera'];
      participant.importError = StateError('invalid archive');
      await expectLater(
        transfer.download(connection, scope: scope),
        throwsStateError,
      );
      expect(participant.notifications, 0);
      expect(participant.syncTime, isNull);
      expect(directory.listSync(), isEmpty);
      expect(remote.closed, isTrue);
    },
  );
}

class _Participant implements DataSyncParticipant {
  _Participant(this.cachePath);
  @override
  final String cachePath;
  @override
  int version = 7;
  bool? excludeFields;
  bool applied = true;
  Object? importError;
  Future<void>? importGate;
  final importStarted = Completer<void>();
  int imports = 0;
  int notifications = 0;
  int? syncTime;

  @override
  Future<int> prepareUploadVersion() async => ++version;
  @override
  Future<File> exportData(bool excludeFields) async {
    this.excludeFields = excludeFields;
    return File('$cachePath/export.venera').writeAsBytes([1, 2, 3]);
  }

  @override
  Future<bool> importData(File file, {required RequestScope scope}) async {
    scope.check();
    expect(await file.readAsBytes(), [4, 5]);
    scope.check();
    imports++;
    importStarted.complete();
    await importGate;
    final error = importError;
    if (error != null) throw error;
    return applied;
  }

  @override
  void notifyImported() {
    expect(imports, 1);
    notifications++;
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async =>
      syncTime = milliseconds;
}

class _Remote implements DataSyncRemote {
  List<String> names = [];
  final removed = <String>[];
  String? written;
  Uint8List? bytes;
  String? readPath;
  Object? writeError;
  bool closed = false;
  int closeCount = 0;
  Future<void>? readGate;
  final readStarted = Completer<void>();
  Future<void>? listGate;
  final listStarted = Completer<void>();
  @override
  Future<List<String>> listNames() async {
    listStarted.complete();
    await listGate;
    return List.of(names);
  }

  @override
  Future<void> remove(String name) async => removed.add(name);
  @override
  Future<void> write(String name, Uint8List bytes) async {
    final error = writeError;
    if (error != null) throw error;
    written = name;
    this.bytes = bytes;
  }

  @override
  Future<void> readToFile(String name, String path) async {
    readPath = path;
    readStarted.complete();
    await readGate;
    await File(path).writeAsBytes([4, 5]);
  }

  @override
  void dispose() {
    closed = true;
    closeCount++;
  }
}
