import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:zip_flutter/zip_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final corruptPhase in [false, true]) {
    test(
      'unreadable import ${corruptPhase ? 'phase' : 'resource manifest'} retains recovery evidence and sync marker',
      () async {
        final root = Directory.systemTemp.createTempSync('import-journal-bad-');
        App.dataPath = (Directory('${root.path}/data')..createSync()).path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        final previous = appdata.captureImportCheckpoint();
        final previousImplicit = Map<String, dynamic>.of(appdata.implicitData);
        final original = StateError('new metadata persistence failed');
        final originalStack = StackTrace.fromString(
          'original metadata failure',
        );
        var injected = false;
        DataSyncController? controller;
        try {
          appdata.settings['dataVersion'] = 7;
          appdata.settings['webdav'] = ['https://example.com/dav', '', ''];
          appdata.settings['disableSyncFields'] = '';
          appdata.searchHistory = ['before import'];
          appdata.implicitData
            ..clear()
            ..addAll({'webdavSyncMode': 'manual', 'webdavSyncPending': true});
          await appdata.saveData(false);
          _writeDatabase('${App.dataPath}/history.db', 'old history');
          final incoming = '${root.path}/history.db';
          _writeDatabase(incoming, 'new history');
          final metadata = File('${root.path}/appdata.json')
            ..writeAsStringSync(
              jsonEncode({
                'settings': {'dataVersion': 8},
                'searchHistory': ['incoming import'],
              }),
            );
          final archive = File('${root.path}/snapshot.venera');
          final zip = ZipFile.open(archive.path);
          try {
            zip.addFile('history.db', incoming);
            zip.addFile('appdata.json', metadata.path);
          } finally {
            zip.close();
          }
          final transfer = _ImportTransfer(archive);
          controller = DataSyncController(
            preferences: createAppSyncPreferences(appdata),
            transfer: () => transfer,
            saveSettings: () => appdata.saveData(false),
            persistImplicit: appdata.writeImplicitData,
            observeChanges: (_) => () {},
          );
          final hooks = _MetadataFailure('${App.dataPath}/appdata.json.tmp', (
            content,
          ) {
            if (injected || !content.contains('"dataVersion":8')) return;
            injected = true;
            final db = sqlite3.open('${App.dataPath}/.app-data-import.sqlite');
            try {
              expect(
                _readDatabase('${App.dataPath}/history.db'),
                'new history',
              );
              expect(
                db
                    .select('SELECT phase FROM import_operations')
                    .single['phase'],
                'applying',
              );
              if (corruptPhase) {
                db.execute("UPDATE import_operations SET phase='invalid' ");
              } else {
                db.execute(
                  "DELETE FROM import_resources WHERE name='appdata.json.bak'",
                );
              }
            } finally {
              db.dispose();
            }
            Error.throwWithStackTrace(original, originalStack);
          });
          final result = await IOOverrides.runWithIOOverrides(
            controller.downloadData,
            hooks,
          );
          await controller.flushPersistence();
          expect(injected, isTrue);
          expect(result.error, isTrue);
          final failure = result.failure as DataSyncFailure;
          expect(failure.commitState, DataSyncCommitState.recoveryRequired);
          expect(
            failure.failures.map((entry) => entry.error),
            contains(same(original)),
          );
          expect(
            failure.failures
                .firstWhere((entry) => identical(entry.error, original))
                .stack
                .toString(),
            originalStack.toString(),
          );
          expect(
            failure.failures.map((entry) => entry.error),
            contains(isA<FormatException>()),
          );
          expect(
            failure.failures.any(
              (entry) => entry.stage == 'remove import backup',
            ),
            isFalse,
          );
          expect(failure.recoveryPath, isNotNull);
          expect(
            _readDatabase('${failure.recoveryPath}/before/history.db'),
            'old history',
          );
          expect(
            File('${failure.recoveryPath}/before/appdata.json').existsSync(),
            isTrue,
          );
          if (corruptPhase) {
            // An unreadable outcome cannot authorize rollback of a possibly
            // committed image. Preserve the installed database untouched.
            expect(_readDatabase('${App.dataPath}/history.db'), 'new history');
          } else {
            expect(HistoryManager.cache?.isInitialized, isFalse);
          }
          expect(controller.hasPendingChanges, isTrue);
          final persisted =
              jsonDecode(
                    File(
                      '${App.dataPath}/implicitData.json',
                    ).readAsStringSync(),
                  )
                  as Map;
          final marker = persisted['webdavSyncOperation'] as Map;
          expect(marker['commitState'], 'recoveryRequired');
          expect(marker['id'], transfer.operationId);
          expect(marker['followUpComplete'], isFalse);
          final journal = sqlite3.open(
            '${App.dataPath}/.app-data-import.sqlite',
          );
          try {
            final row = journal
                .select('SELECT * FROM import_operations')
                .single;
            expect(row['sync_id'], transfer.operationId);
            expect(row['cleaned'], 0);
          } finally {
            journal.dispose();
          }
          final repeated = await controller.downloadData();
          expect(repeated.error, isTrue);
          expect(
            (repeated.failure as DataSyncFailure).commitState,
            DataSyncCommitState.recoveryRequired,
          );
          expect(transfer.calls, 1);
          final metadataBeforeRetry = File(
            '${App.dataPath}/appdata.json',
          ).readAsStringSync();
          final historyReady = HistoryManager.cache?.isInitialized;
          // The manual importer shares the same admission rule even when it
          // bypasses the sync controller and its in-memory recovery guard.
          await expectLater(
            importAppData(archive),
            throwsA(
              isA<DataSyncImportFailure>().having(
                (error) => error.commitState,
                'commitState',
                DataSyncCommitState.recoveryRequired,
              ),
            ),
          );
          expect(
            File('${App.dataPath}/appdata.json').readAsStringSync(),
            metadataBeforeRetry,
          );
          expect(HistoryManager.cache?.isInitialized, historyReady);
        } finally {
          controller?.dispose();
          HistoryManager.cache?.close();
          await appdata.restoreImportCheckpoint(previous, persist: false);
          appdata.implicitData
            ..clear()
            ..addAll(previousImplicit);
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}

void _writeDatabase(String path, String value) {
  final db = sqlite3.open(path);
  try {
    db.execute('CREATE TABLE marker (value TEXT NOT NULL)');
    db.execute('INSERT INTO marker VALUES (?)', [value]);
  } finally {
    db.dispose();
  }
}

String _readDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    return db.select('SELECT value FROM marker').single['value'] as String;
  } finally {
    db.dispose();
  }
}

class _ImportTransfer implements DataSyncTransfer {
  _ImportTransfer(this.archive);
  final File archive;
  String? operationId;
  int calls = 0;

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    bool force = false,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async {
    calls++;
    operationId = syncOperationId;
    return await importSyncAppData(
          archive,
          checkActive: scope.check,
          force: force,
          publishImported: publishImported,
          syncOperationId: syncOperationId,
        ) ==
        DataSyncCommitState.applied;
  }

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) => throw UnsupportedError('download-only fixture');
}

final class _MetadataFailure extends IOOverrides {
  _MetadataFailure(this.target, this.beforeWrite);
  final String target;
  final void Function(String content) beforeWrite;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.replaceAll('\\', '/') == target.replaceAll('\\', '/')
        ? _MetadataFile(file, beforeWrite)
        : file;
  }
}

class _MetadataFile implements File {
  _MetadataFile(this.raw, this.beforeWrite);
  final File raw;
  final void Function(String content) beforeWrite;

  @override
  String get path => raw.path;
  @override
  Future<bool> exists() => raw.exists();
  @override
  Future<File> delete({bool recursive = false}) async {
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  Future<File> rename(String newPath) => raw.rename(newPath);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    beforeWrite(contents);
    return raw.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
