import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  late Directory directory;
  late Object? previousVersion;
  late Object? previousConnection;
  late List<String> previousSearch;
  late Map<String, dynamic> previousImplicit;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('import-result-');
    App.dataPath = (Directory('${directory.path}/data')..createSync()).path;
    App.cachePath = (Directory('${directory.path}/cache')..createSync()).path;
    previousVersion = appdata.settings['dataVersion'];
    previousConnection = appdata.settings['webdav'];
    previousSearch = List.of(appdata.searchHistory);
    previousImplicit = Map.of(appdata.implicitData);
    appdata.settings['dataVersion'] = 7;
    appdata.settings['webdav'] = ['https://example.com', '', ''];
    appdata.searchHistory = ['local'];
    appdata.implicitData['webdavSyncPending'] = true;
  });

  tearDown(() async {
    await appdata.saveData(false);
    appdata.settings['dataVersion'] = previousVersion;
    appdata.settings['webdav'] = previousConnection;
    appdata.searchHistory = previousSearch;
    appdata.implicitData.clear();
    appdata.implicitData.addAll(previousImplicit);
    directory.deleteSync(recursive: true);
  });

  File archive(int version) {
    final metadata = File('${directory.path}/appdata.json')
      ..writeAsStringSync(
        jsonEncode({
          'settings': {'dataVersion': version},
          'searchHistory': ['remote'],
        }),
      );
    final file = File('${directory.path}/snapshot.venera');
    final zip = ZipFile.open(file.path);
    zip.addFile('appdata.json', metadata.path);
    zip.close();
    return file;
  }

  test(
    'sync import cancelled while queued never starts applying data',
    () async {
      final scope = RequestScope();
      addTearDown(scope.dispose);
      final gate = Completer<void>();
      final blocker = AppDataOperations.instance.run(() => gate.future);
      final importing = importSyncAppData(archive(8), checkActive: scope.check);
      final checked = expectLater(importing, throwsA(isA<RequestCancelled>()));
      scope.cancel();
      gate.complete();
      await blocker;
      await checked;
      expect(appdata.settings['dataVersion'], 7);
      expect(appdata.searchHistory, ['local']);
      expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
    },
  );

  test(
    'cancellation after archive validation leaves existing data unchanged',
    () async {
      var checks = 0;
      await expectLater(
        importSyncAppData(
          archive(8),
          checkActive: () {
            checks++;
            if (checks == 2) throw const RequestCancelled();
          },
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(checks, 2);
      expect(appdata.settings['dataVersion'], 7);
      expect(appdata.searchHistory, ['local']);
      expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
    },
  );

  test(
    'embedded equal or older version returns skipped without applying data',
    () async {
      for (final version in [6, 7]) {
        expect(await importAppData(archive(version), true), isFalse);
        expect(appdata.settings['dataVersion'], 7);
        expect(appdata.searchHistory, ['local']);
        expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
      }
    },
  );

  test('newer embedded version returns applied', () async {
    expect(await importAppData(archive(8), true), isTrue);
    expect(appdata.settings['dataVersion'], 8);
    expect(appdata.searchHistory, ['remote']);
  });

  test('manual import can still apply an older archive', () async {
    expect(await importAppData(archive(6)), isTrue);
    expect(appdata.settings['dataVersion'], 6);
    expect(appdata.searchHistory, ['remote']);
  });

  test('DataSync retains pending edits when archive import skips', () async {
    final sync = _controller(_ArchiveTransfer(archive(7)));
    try {
      expect((await sync.downloadData()).success, isTrue);
      expect(sync.hasPendingChanges, isTrue);
      expect(appdata.searchHistory, ['local']);
    } finally {
      sync.dispose();
    }
  });

  test('DataSync clears pending only after an applied archive', () async {
    final sync = _controller(_ArchiveTransfer(archive(8)));
    try {
      expect((await sync.downloadData()).success, isTrue);
      expect(sync.hasPendingChanges, isFalse);
      expect(appdata.searchHistory, ['remote']);
    } finally {
      sync.dispose();
    }
  });
}

class _ArchiveTransfer implements DataSyncTransfer {
  const _ArchiveTransfer(this.archive);
  final File archive;

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
  }) => importSyncAppData(archive, checkActive: scope.check);

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
  }) async => throw UnsupportedError('download-only fixture');
}

DataSyncController _controller(DataSyncTransfer transfer) => DataSyncController(
  preferences: createAppSyncPreferences(appdata),
  transfer: () => transfer,
  saveSettings: () => appdata.saveData(false),
  persistImplicit: appdata.writeImplicitData,
  observeChanges: (_) => () {},
);
