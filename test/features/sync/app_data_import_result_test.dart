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
    final sync = DataSync.withTransfer(_ArchiveTransfer(archive(7)));
    try {
      expect((await sync.downloadData()).success, isTrue);
      expect(sync.hasPendingChanges, isTrue);
      expect(appdata.searchHistory, ['local']);
    } finally {
      sync.dispose();
    }
  });

  test('DataSync clears pending only after an applied archive', () async {
    final sync = DataSync.withTransfer(_ArchiveTransfer(archive(8)));
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
  Future<bool> download(WebDavEndpoint connection) =>
      importAppData(archive, true);

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
  }) async => throw UnsupportedError('download-only fixture');
}
