import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  late Directory directory;
  late _Participant participant;
  late _Remote remote;
  late WebDavDataSyncTransfer transfer;
  final connection = WebDavEndpoint(
    url: 'https://example.com',
    user: '',
    password: '',
  );
  setUp(() {
    directory = Directory.systemTemp.createTempSync('data-transfer-');
    participant = _Participant(directory.path);
    remote = _Remote();
    transfer = WebDavDataSyncTransfer(
      participant: participant,
      openRemote: (_) => remote,
      now: () => DateTime.fromMillisecondsSinceEpoch(20 * 86400000),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'upload preserves archive naming, exclusion and retention protocol',
    () async {
      remote.names = ['19-4.venera', '20-5.venera', 'notes.txt'];
      await transfer.upload(connection, excludeFields: true);
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
      transfer.upload(connection, excludeFields: false),
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
      expect(await transfer.download(connection), isFalse);
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
    expect(await transfer.download(connection), isFalse);
    expect(participant.imports, 1);
    expect(participant.notifications, 0);
    expect(participant.syncTime, isNull);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'applied snapshot notifies only after import and uses isolated local path',
    () async {
      remote.names = ['../20-8.venera'];
      expect(await transfer.download(connection), isTrue);
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
      await expectLater(transfer.download(connection), throwsStateError);
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
  Future<bool> importData(File file) async {
    expect(await file.readAsBytes(), [4, 5]);
    imports++;
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
  @override
  Future<List<String>> listNames() async => List.of(names);
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
    await File(path).writeAsBytes([4, 5]);
  }

  @override
  void dispose() => closed = true;
}
