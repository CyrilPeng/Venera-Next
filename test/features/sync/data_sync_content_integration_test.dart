import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/app_runtime/data_sync.dart';
import 'package:venera_next/app_runtime/data_sync_content.dart';
import 'package:venera_next/app_runtime/data_sync_transfer.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/sync/data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async => fixture = await _Fixture.create());
  tearDown(() => fixture.close());

  test(
    'production restart resolves a download that never reached import',
    () async {
      final operation = DataSyncOperation(
        id: '11111111-1111-4111-8111-111111111111',
        direction: DataSyncDirection.download,
        connection: List<String>.from(appdata.settings['webdav'] as List),
        excludedFields: '',
        mode: 'manual',
        intervalMinutes: 15,
        pendingBefore: false,
        generation: 0,
        commitState: DataSyncCommitState.notApplied,
        followUpComplete: false,
        version: 4,
      );
      final journal = DataSyncContentJournal.open(App.dataPath);
      try {
        journal.begin(
          id: operation.id,
          direction: 'download',
          scope: DataSyncContentScope(
            endpoint: dataSyncEndpointFingerprint(operation.connection),
            excludedFields: '',
            archiveSyncEnabled: false,
          ),
          before: 'a' * 64,
        );
      } finally {
        journal.close();
      }
      appdata.implicitData['webdavSyncOperation'] = operation.toJson();
      await appdata.writeImplicitData();
      final result = await fixture.controller.downloadData();
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(fixture.remote.reads, 0);
      expect(appdata.searchHistory, ['local-content']);
      expect(appdata.implicitData['webdavSyncOperation'], isNull);
      final reopened = DataSyncContentJournal.open(App.dataPath);
      try {
        expect(reopened.records, isEmpty);
      } finally {
        reopened.close();
      }
    },
  );

  test(
    'production owner remains held until a cancelled real transfer drains',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.releases.add(release);
      fixture.remote.beforePut = () async {
        entered.complete();
        await release.future;
      };
      final upload = fixture.controller.uploadData();
      await entered.future;
      var closed = false;
      final closing = fixture.controller.closeAndWait();
      final observed = closing.then((_) {
        closed = true;
      });
      final contender = createApplicationDataSync();
      contender.start();
      expect(contender.lastError, contains('locked'));
      await contender.closeAndWait();
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      await upload;
      await observed;
    },
  );

  test(
    'production upload confirms its actual archive and leaves content clean',
    () async {
      final result = await fixture.controller.uploadData();
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(await fixture.inspect(), DataSyncContentState.clean);
      expect(fixture.controller.hasPendingChanges, isFalse);
      expect(fixture.remote.puts, 1);
      expect(appdata.implicitData['webdavSyncOperation'], isNull);
      final db = sqlite3.open(
        '${App.dataPath}/${DataSyncContentJournal.fileName}',
      );
      try {
        expect(db.select('SELECT * FROM content_operations'), isEmpty);
        expect(db.select('SELECT * FROM content_baselines'), hasLength(1));
      } finally {
        db.dispose();
      }
      // Transport bookkeeping is persisted after export and must not be echoed.
      await appdata.updateSettings((settings) {
        settings['lastSyncTime'] = 999;
        settings['dataVersion'] = 99;
      }, sync: false);
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );

  for (final kind in ['history', 'cookie', 'source']) {
    test(
      'restart detects unannounced $kind commits with pending=false',
      () async {
        expect((await fixture.controller.uploadData()).success, isTrue);
        await fixture.writeUnannounced(kind);
        expect(fixture.controller.hasPendingChanges, isFalse);
        await fixture.rebuild();
        expect(await fixture.inspect(), DataSyncContentState.changed);
        appdata.implicitData['webdavSyncMode'] = 'realtime';
        fixture.controller.start();
        await _until(
          () => fixture.remote.puts == 2 && !fixture.controller.isUploading,
        );
        fixture.controller.stop();
        expect(fixture.controller.hasPendingChanges, isFalse);
        expect(await fixture.inspect(), DataSyncContentState.clean);
      },
    );
  }

  test(
    'writes during PUT remain dirty after the older archive is confirmed',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.releases.add(release);
      fixture.remote.beforePut = () async {
        entered.complete();
        await release.future;
      };
      final uploading = fixture.controller.uploadData();
      await entered.future;
      await fixture.writeUnannounced('cookie');
      release.complete();
      final result = await uploading;
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(await fixture.inspect(), DataSyncContentState.changed);
      expect(fixture.controller.hasPendingChanges, isTrue);
      fixture.remote.beforePut = null;
      expect((await fixture.controller.uploadData()).success, isTrue);
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );

  test(
    'realtime content check schedules the edit made during its own upload',
    () async {
      expect((await fixture.controller.uploadData()).success, isTrue);
      await fixture.writeUnannounced('source');
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.releases.add(release);
      fixture.remote.beforePut = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      fixture.controller.start();
      await entered.future;
      await fixture.writeUnannounced('cookie');
      release.complete();
      await _until(
        () => fixture.remote.puts == 3 && !fixture.controller.isUploading,
      );
      fixture.controller.stop();
      expect(await fixture.inspect(), DataSyncContentState.clean);
      expect(fixture.controller.hasPendingChanges, isFalse);
    },
  );

  test(
    'download rejects local changes made during network wait before replacement',
    () async {
      expect((await fixture.controller.uploadData()).success, isTrue);
      fixture.remote.files.clear();
      fixture.publishRemoteMetadata();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.releases.add(release);
      fixture.remote.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final downloading = fixture.controller.downloadData();
      await entered.future;
      await appdata.addSearchHistory('local-during-network');
      release.complete();
      final result = await downloading;
      expect(result.error, isTrue);
      expect(
        result.errorMessage,
        contains('Local data changed while downloading'),
      );
      expect(appdata.searchHistory, contains('local-during-network'));
      expect(appdata.searchHistory, isNot(contains('remote-content')));
      expect(await fixture.inspect(), DataSyncContentState.changed);
      expect(fixture.controller.hasPendingChanges, isTrue);
      expect(appdata.implicitData['webdavSyncOperation'], isNull);
    },
  );

  test(
    'an applied metadata import establishes a clean baseline after real follow-up writes',
    () async {
      fixture.publishRemoteMetadata();
      final result = await fixture.controller.downloadData();
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(appdata.searchHistory, ['remote-content']);
      expect(await fixture.inspect(), DataSyncContentState.clean);
      expect(fixture.controller.hasPendingChanges, isFalse);
      await fixture.rebuild();
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );

  test(
    'missing baseline stops automatic direction selection until explicit upload',
    () async {
      fixture.publishRemoteMetadata();
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      fixture.controller.start();
      await _until(() => fixture.controller.lastError != null);
      expect(fixture.controller.lastError, contains('Complete an upload'));
      expect(fixture.remote.reads, 0);
      expect(fixture.remote.puts, 0);
      expect((await fixture.controller.uploadData()).success, isTrue);
      fixture.controller.stop();
      expect(await fixture.inspect(), DataSyncContentState.clean);
      await fixture.controller.flushPersistence();
    },
  );

  test('baseline scope changes require a new explicit direction', () async {
    expect((await fixture.controller.uploadData()).success, isTrue);
    appdata.settings['disableSyncFields'] = 'language';
    expect(await fixture.inspect(), DataSyncContentState.unknown);
    appdata.settings['disableSyncFields'] = '';
    expect(await fixture.inspect(), DataSyncContentState.clean);
    appdata.settings['webdav'] = ['https://different.example', '', ''];
    expect(await fixture.inspect(), DataSyncContentState.unknown);
  });

  test(
    'custom archive-field exclusion stays clean after upload but protects incoming edits',
    () async {
      await appdata.updateSettings((settings) {
        settings['backupWebdavSyncEnabled'] = true;
        settings['disableSyncFields'] = 'backupWebdav';
        settings['backupWebdav'] = ['https://archive.example', '', ''];
      }, sync: false);
      final uploaded = await fixture.controller.uploadData();
      expect(uploaded.success, isTrue, reason: uploaded.errorMessage);
      expect(await fixture.inspect(), DataSyncContentState.clean);
      expect(fixture.controller.hasPendingChanges, isFalse);
      fixture.remote.files.clear();
      fixture.publishRemoteMetadata(
        extraSettings: {
          'backupWebdav': ['https://remote-archive.example', '', ''],
        },
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.releases.add(release);
      fixture.remote.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final downloading = fixture.controller.downloadData();
      await entered.future;
      await appdata.updateSettings((settings) {
        settings['backupWebdav'] = ['https://local-edit.example', '', ''];
      }, sync: false);
      release.complete();
      final downloaded = await downloading;
      expect(downloaded.error, isTrue);
      expect(
        downloaded.errorMessage,
        contains('Local data changed while downloading'),
      );
      expect(
        (appdata.settings['backupWebdav'] as List).first,
        'https://local-edit.example',
      );
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );

  for (final field in ['disableSyncFields', 'backupWebdavSyncEnabled']) {
    test(
      'download refuses a changed $field policy before applying data',
      () async {
        expect((await fixture.controller.uploadData()).success, isTrue);
        fixture.remote.files.clear();
        fixture.publishRemoteMetadata();
        fixture.remote.beforeRead = () => appdata.updateSettings((settings) {
          settings[field] = field == 'disableSyncFields' ? 'language' : true;
        }, sync: false);
        final result = await fixture.controller.downloadData();
        expect(result.error, isTrue);
        expect(
          result.errorMessage,
          contains('Local data changed while downloading'),
        );
        expect(appdata.searchHistory, ['local-content']);
      },
    );
  }

  test('failed comparison can be repaired and explicitly retried', () async {
    expect((await fixture.controller.uploadData()).success, isTrue);
    final file = File('${App.dataPath}/appdata.json');
    final saved = file.readAsBytesSync();
    file.writeAsStringSync('{broken');
    appdata.implicitData['webdavSyncMode'] = 'realtime';
    fixture.controller.start();
    await _until(() => fixture.controller.lastError != null);
    fixture.controller.stop();
    file.writeAsBytesSync(saved);
    expect((await fixture.controller.uploadData()).success, isTrue);
    await fixture.controller.flushPersistence();
    expect(await fixture.inspect(), DataSyncContentState.clean);
  });

  test(
    'automatic restart resolves an interrupted first upload before requiring a baseline',
    () async {
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      fixture.remote.losePutResponse = true;
      expect((await fixture.controller.uploadData()).error, isTrue);
      expect(await fixture.inspect(), DataSyncContentState.unknown);
      expect(fixture.remote.puts, 1);
      await fixture.rebuild();
      fixture.controller.start();
      await _until(
        () =>
            appdata.implicitData['webdavSyncOperation'] == null &&
            !fixture.controller.isUploading,
      );
      fixture.controller.stop();
      expect(fixture.remote.puts, 1);
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );

  test(
    'missing candidate retains applied receipt and retry uses restored original evidence',
    () async {
      late List<Object?> record;
      fixture.remote.beforePut = () async {
        final db = sqlite3.open(
          '${App.dataPath}/${DataSyncContentJournal.fileName}',
        );
        try {
          record = db
              .select('SELECT * FROM content_operations')
              .single
              .values
              .toList();
          db.execute('DELETE FROM content_operations');
        } finally {
          db.dispose();
        }
      };
      final result = await fixture.controller.uploadData();
      expect(result.error, isTrue);
      expect(
        result.errorMessage,
        contains('Missing synchronized content evidence'),
      );
      expect(appdata.implicitData['webdavSyncOperation'], isNotNull);
      expect(await fixture.inspect(), DataSyncContentState.unknown);
      final db = sqlite3.open(
        '${App.dataPath}/${DataSyncContentJournal.fileName}',
      );
      try {
        db.execute(
          'INSERT INTO content_operations VALUES (?, ?, ?, ?, ?)',
          record,
        );
      } finally {
        db.dispose();
      }
      fixture.remote.beforePut = null;
      expect((await fixture.controller.uploadData()).success, isTrue);
      expect(fixture.remote.puts, 1);
      expect(await fixture.inspect(), DataSyncContentState.clean);
    },
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Sync did not reach the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _Fixture {
  _Fixture(this.root, this.previous, this.previousImplicit);
  final Directory root;
  final Map<String, dynamic> previous;
  final Map<String, dynamic> previousImplicit;
  final remote = _Remote();
  final releases = <Completer<void>>[];
  late CookieJarSql cookies;
  late DataSyncController controller;

  static Future<_Fixture> create() async {
    final fixture = _Fixture(
      Directory.systemTemp.createTempSync('sync-content-app-'),
      jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>,
      Map<String, dynamic>.from(appdata.implicitData),
    );
    App.dataPath = (Directory('${fixture.root.path}/data')..createSync()).path;
    App.cachePath = (Directory(
      '${fixture.root.path}/cache',
    )..createSync()).path;
    App.version = '9.0.0';
    appdata.settings['webdav'] = ['https://example.com', '', ''];
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['backupWebdavSyncEnabled'] = false;
    appdata.settings['dataVersion'] = 7;
    appdata.searchHistory = ['local-content'];
    appdata.implicitData
      ..clear()
      ..addAll({'webdavSyncPending': false, 'webdavSyncMode': 'manual'});
    await appdata.saveData(false);
    await appdata.init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
    fixture.cookies = CookieJarSql('${App.dataPath}/cookie.db');
    Directory('${App.dataPath}/comic_source').createSync();
    File(
      '${App.dataPath}/comic_source/one.data',
    ).writeAsStringSync('{"value":1}');
    fixture._createController();
    return fixture;
  }

  void _createController() {
    final transfer = createDataSyncTransfer(openRemote: (_) => remote);
    controller = createApplicationDataSync(
      transfer: () => transfer,
      uploadRecovery: transfer,
    );
  }

  Future<void> rebuild() async {
    await controller.closeAndWait();
    appdata.implicitData
      ..clear()
      ..addAll(
        jsonDecode(File('${App.dataPath}/implicitData.json').readAsStringSync())
            as Map<String, dynamic>,
      );
    _createController();
  }

  Future<DataSyncContentState> inspect() =>
      ApplicationDataSyncContent().inspect(
        List<String>.from(appdata.settings['webdav'] as List),
        appdata.settings['disableSyncFields'] as String,
      );

  Future<void> writeUnannounced(String kind) async {
    if (kind == 'cookie') {
      await cookies.saveFromResponseAsync(Uri.parse('https://example.com'), [
        Cookie('session', 'changed'),
      ]);
    } else if (kind == 'history') {
      final db = sqlite3.open('${App.dataPath}/history.db');
      try {
        db.execute('CREATE TABLE sync_content_regression (value TEXT)');
        db.execute(
          "INSERT INTO sync_content_regression VALUES ('committed-without-notification')",
        );
      } finally {
        db.dispose();
      }
    } else {
      File(
        '${App.dataPath}/comic_source/one.data',
      ).writeAsStringSync('{"value":2}', flush: true);
    }
  }

  void publishRemoteMetadata({Map<String, Object?> extraSettings = const {}}) {
    final metadata = File('${root.path}/remote.json')
      ..writeAsStringSync(
        jsonEncode({
          'settings': {'dataVersion': 200, ...extraSettings},
          'searchHistory': ['remote-content'],
        }),
      );
    final file = File('${root.path}/remote.venera');
    final zip = ZipFile.open(file.path);
    zip.addFile('appdata.json', metadata.path);
    zip.close();
    remote.files['99999-200.venera'] = file.readAsBytesSync();
  }

  Future<void> close() async {
    for (final release in releases) {
      if (!release.isCompleted) release.complete();
    }
    controller.dispose();
    await controller.flushPersistence();
    await HistoryManager().waitForAsyncWrites();
    HistoryManager().close();
    await LocalFavoritesManager().closeAndWait();
    cookies.dispose();
    await appdata.saveData(false);
    for (final entry
        in (previous['settings'] as Map<String, dynamic>).entries) {
      appdata.settings[entry.key] = entry.value;
    }
    appdata.searchHistory = List<String>.from(
      previous['searchHistory'] as List,
    );
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    root.deleteSync(recursive: true);
  }
}

class _Remote implements DataSyncRemote {
  final files = <String, Uint8List>{};
  Future<void> Function()? beforePut;
  Future<void> Function()? beforeRead;
  int puts = 0;
  int reads = 0;
  bool losePutResponse = false;
  String _hash(List<int> bytes) => crypto.sha256.convert(bytes).toString();
  @override
  Future<List<String>> listNames() async => files.keys.toList();
  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) async {
    final bytes = files[name];
    return bytes == null
        ? const DataSyncArchiveMissing()
        : DataSyncArchivePresent(
            sha256: _hash(bytes),
            length: bytes.length,
            strongEtag: '"${_hash(bytes)}"',
          );
  }

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    await beforePut?.call();
    if (files.containsKey(name)) {
      return DataSyncArchiveCreateResult.preconditionFailed;
    }
    final bytes = source.readAsBytesSync();
    expect(_hash(bytes), sha256);
    expect(bytes.length, length);
    files[name] = bytes;
    puts++;
    if (losePutResponse) {
      losePutResponse = false;
      throw const SocketException('Stored PUT response was lost');
    }
    return DataSyncArchiveCreateResult.created;
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    final bytes = files[name];
    if (bytes == null) return DataSyncArchiveRemoveResult.missing;
    if (strongEtag != '"${_hash(bytes)}"') {
      return DataSyncArchiveRemoveResult.preconditionFailed;
    }
    files.remove(name);
    return DataSyncArchiveRemoveResult.removed;
  }

  @override
  Future<void> readToFile(String name, String path) async {
    reads++;
    await beforeRead?.call();
    await File(path).writeAsBytes(files[name]!, flush: true);
  }

  @override
  Future<void> dispose() async {}
}
