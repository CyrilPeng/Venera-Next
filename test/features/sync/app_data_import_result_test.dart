import 'dart:async';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_transaction_journal.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/app_runtime/data_sync.dart';
import 'package:venera_next/app_runtime/data_sync_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Object? previousVersion;
  late Object? previousConnection;
  late Object? previousSyncTime;
  late List<String> previousSearch;
  late Map<String, dynamic> previousImplicit;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('import-result-');
    App.dataPath = (Directory('${directory.path}/data')..createSync()).path;
    App.cachePath = (Directory('${directory.path}/cache')..createSync()).path;
    previousVersion = appdata.settings['dataVersion'];
    previousConnection = appdata.settings['webdav'];
    previousSyncTime = appdata.settings['lastSyncTime'];
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
    appdata.settings['lastSyncTime'] = previousSyncTime;
    appdata.searchHistory = previousSearch;
    appdata.implicitData.clear();
    appdata.implicitData.addAll(previousImplicit);
    directory.deleteSync(recursive: true);
  });

  File archive(
    int version, {
    bool includeSources = false,
    bool includeFavorites = false,
  }) {
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
    if (includeSources) {
      final marker = File('${directory.path}/empty-source-marker')
        ..writeAsStringSync('No source scripts');
      zip.addFile('comic_source/.keep', marker.path);
    }
    if (includeFavorites) {
      final incoming = '${directory.path}/local_favorite.db';
      _writeMarker(incoming, 'remote-favorite');
      zip.addFile('local_favorite.db', incoming);
    }
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
    'cancellation after preparing a source backup does not reload untouched sources',
    () async {
      var checks = 0;
      // No JS engine is initialized: cancellation before replacement must not
      // try source reload or wait for an engine that the importer never needed.
      await expectLater(
        importSyncAppData(
          archive(8, includeSources: true),
          checkActive: () {
            if (++checks == 5) throw const RequestCancelled();
          },
        ),
        throwsA(isA<RequestCancelled>()),
      );
      expect(checks, 5);
      expect(appdata.settings['dataVersion'], 7);
      expect(appdata.searchHistory, ['local']);
      expect(Directory('${App.dataPath}/comic_source').existsSync(), isFalse);
    },
  );

  test(
    'embedded equal or older version returns skipped without applying data',
    () async {
      for (final version in [6, 7]) {
        expect(
          await importAppData(archive(version), true),
          DataSyncCommitState.notApplied,
        );
        expect(appdata.settings['dataVersion'], 7);
        expect(appdata.searchHistory, ['local']);
        expect(Directory('${App.cachePath}/temp_data').existsSync(), isFalse);
      }
    },
  );

  test('newer embedded version returns applied', () async {
    expect(await importAppData(archive(8), true), DataSyncCommitState.applied);
    expect(appdata.settings['dataVersion'], 8);
    expect(appdata.searchHistory, ['remote']);
  });

  test(
    'pending source transaction blocks import before settings change',
    () async {
      final script = File('${App.dataPath}/comic_source/one.js');
      script.parent.createSync();
      final pending = await SourceTransactionJournal.begin(
        dataPath: App.dataPath,
        script: script,
        before: null,
        after: utf8.encode('new source'),
      );
      await pending.writeScript();
      await pending.close();
      await expectLater(importAppData(archive(8)), throwsStateError);
      expect(appdata.settings['dataVersion'], 7);
      expect(appdata.searchHistory, ['local']);
      expect(script.readAsStringSync(), 'new source');
      await SourceTransactionJournal.recover(App.dataPath);
      expect(script.existsSync(), isFalse);
      expect(await importAppData(archive(8)), DataSyncCommitState.applied);
    },
  );

  test('manual import can still apply an older archive', () async {
    expect(await importAppData(archive(6)), DataSyncCommitState.applied);
    expect(appdata.settings['dataVersion'], 6);
    expect(appdata.searchHistory, ['remote']);
  });

  test(
    'import waits for its actual appdata write without requesting upload',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var uploads = 0;
      appdata.registerSyncDataRequestHandler(() => uploads++);
      addTearDown(() => appdata.registerSyncDataRequestHandler(null));
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final hooks = _ImportIOHooks()
        ..beforeWrite = (path, content) async {
          if (p.basename(path) == 'appdata.json.tmp' &&
              content.contains('"dataVersion":8')) {
            entered.complete();
            await release.future;
          }
        };
      var finished = false;
      final importing = IOOverrides.runWithIOOverrides(
        () => importAppData(archive(8)).then((value) {
          finished = true;
          return value;
        }),
        hooks,
      );
      await entered.future;
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(
        jsonDecode(
          File('${App.dataPath}/appdata.json').readAsStringSync(),
        )['settings']['dataVersion'],
        7,
      );
      release.complete();
      expect(await importing, DataSyncCommitState.applied);
      final persisted = jsonDecode(
        File('${App.dataPath}/appdata.json').readAsStringSync(),
      );
      expect(persisted['settings']['dataVersion'], 8);
      expect(persisted['searchHistory'], ['remote']);
      expect(uploads, 0);
    },
  );

  for (final failRollback in [false, true]) {
    test(
      'metadata write failure restores the exact checkpoint; rollbackFails=$failRollback',
      () async {
        final original = StateError('new metadata write failed');
        final originalStack = StackTrace.fromString('new metadata stack');
        final rollback = StateError('old metadata write failed');
        final rollbackStack = StackTrace.fromString('old metadata stack');
        var newWriteAttempted = false;
        final hooks = _ImportIOHooks()
          ..beforeWrite = (path, content) async {
            if (p.basename(path) != 'appdata.json.tmp') return;
            if (content.contains('"dataVersion":8')) {
              newWriteAttempted = true;
              Error.throwWithStackTrace(original, originalStack);
            }
            if (failRollback && newWriteAttempted) {
              Error.throwWithStackTrace(rollback, rollbackStack);
            }
          };
        final captured = await _captureImport(
          IOOverrides.runWithIOOverrides(
            () => importAppData(archive(8)),
            hooks,
          ),
        );
        final error = captured.error as DataSyncImportFailure;
        expect(
          error.commitState,
          failRollback
              ? DataSyncCommitState.recoveryRequired
              : DataSyncCommitState.notApplied,
        );
        expect(error.cause, same(original));
        expect(error.stackTrace.toString(), originalStack.toString());
        expect(error.resume, isNull);
        expect(appdata.settings['dataVersion'], 7);
        expect(appdata.searchHistory, ['local']);
        if (failRollback) {
          expect(error.failures.last.error, same(rollback));
          expect(
            error.failures.last.stack.toString(),
            rollbackStack.toString(),
          );
          final checkpoint = File('${error.recoveryPath}/before/appdata.json');
          expect(checkpoint.existsSync(), isTrue);
          expect(
            jsonDecode(
              checkpoint.readAsStringSync(),
            )['settings']['dataVersion'],
            7,
          );
        } else {
          expect(error.failures, hasLength(1));
          expect(
            Directory(App.dataPath).listSync().where(
              (entry) => p.basename(entry.path).startsWith('.app-data-import-'),
            ),
            isEmpty,
          );
          expect(
            jsonDecode(
              File('${App.dataPath}/appdata.json').readAsStringSync(),
            )['searchHistory'],
            ['local'],
          );
        }
      },
    );
  }

  test(
    'checkpoint rollback removes imported keys and restores nested values',
    () async {
      final checkpoint = appdata.captureImportCheckpoint();
      final previous = jsonDecode(checkpoint.json) as Map;
      await appdata.syncData({
        'settings': {
          'importedOnly': {
            'nested': ['new'],
          },
        },
        'searchHistory': ['changed'],
      });
      List<String>? observedHistory;
      void listener() => observedHistory = List.of(appdata.searchHistory);
      appdata.settings.addListener(listener);
      try {
        await appdata.restoreImportCheckpoint(checkpoint);
      } finally {
        appdata.settings.removeListener(listener);
      }
      expect(observedHistory, previous['searchHistory']);
      expect(appdata.toJson(), previous);
      expect(
        jsonDecode(File('${App.dataPath}/appdata.json').readAsStringSync()),
        previous,
      );
    },
  );

  test(
    'both metadata write failures survive the importer rollback result',
    () async {
      final previousExcluded = appdata.settings['disableSyncFields'];
      appdata.settings['disableSyncFields'] = 'proxy';
      final appError = StateError('appdata write');
      final syncError = StateError('syncdata write');
      final appStack = StackTrace.fromString('appdata write stack');
      final syncStack = StackTrace.fromString('syncdata write stack');
      final hooks = _ImportIOHooks()
        ..beforeWrite = (path, content) async {
          if (!content.contains('"dataVersion":8')) return;
          if (p.basename(path) == 'appdata.json.tmp') {
            Error.throwWithStackTrace(appError, appStack);
          }
          if (p.basename(path) == 'syncdata.json.tmp') {
            Error.throwWithStackTrace(syncError, syncStack);
          }
        };
      try {
        final result =
            (await _captureImport(
                  IOOverrides.runWithIOOverrides(
                    () => importAppData(archive(8)),
                    hooks,
                  ),
                )).error
                as DataSyncImportFailure;
        expect(result.commitState, DataSyncCommitState.notApplied);
        final writes = result.cause as AppdataWriteFailure;
        expect(
          writes.failures.map((failure) => failure.error),
          unorderedEquals([same(appError), same(syncError)]),
        );
        expect(
          writes.failures.map((failure) => failure.stack.toString()),
          unorderedEquals([appStack.toString(), syncStack.toString()]),
        );
        expect(
          jsonDecode(
            File('${App.dataPath}/appdata.json').readAsStringSync(),
          )['settings']['dataVersion'],
          7,
        );
        expect(
          jsonDecode(
            File('${App.dataPath}/syncdata.json').readAsStringSync(),
          )['settings']['dataVersion'],
          7,
        );
      } finally {
        appdata.settings['disableSyncFields'] = previousExcluded;
      }
    },
  );

  test(
    'committed cleanup retries only its owned paths after a later import',
    () async {
      final firstHooks = _ImportIOHooks();
      final secondHooks = _ImportIOHooks();
      final failedFirst = <String>[];
      final failedSecond = <String>[];
      var allowFirst = false;
      var allowSecond = false;
      firstHooks.beforeDeleteDirectory = (path) {
        if (!allowFirst) {
          failedFirst.add(path);
          throw FileSystemException('first cleanup held', path);
        }
      };
      secondHooks.beforeDeleteDirectory = (path) {
        if (!allowSecond) {
          failedSecond.add(path);
          throw FileSystemException('second cleanup held', path);
        }
      };
      final first =
          (await _captureImport(
                IOOverrides.runWithIOOverrides(
                  () => importAppData(archive(8)),
                  firstHooks,
                ),
              )).error
              as DataSyncImportFailure;
      final second =
          (await _captureImport(
                IOOverrides.runWithIOOverrides(
                  () => importAppData(archive(9)),
                  secondHooks,
                ),
              )).error
              as DataSyncImportFailure;
      expect(first.commitState, DataSyncCommitState.applied);
      expect(second.commitState, DataSyncCommitState.applied);
      expect(first.failures, hasLength(2));
      expect(second.failures, hasLength(2));
      expect(failedFirst.toSet().intersection(failedSecond.toSet()), isEmpty);
      allowFirst = true;
      expect(await first.resume!(), DataSyncCommitState.applied);
      expect(await first.resume!(), DataSyncCommitState.applied);
      expect(
        failedFirst.every((path) => !Directory(path).existsSync()),
        isTrue,
      );
      expect(
        failedSecond.every((path) => Directory(path).existsSync()),
        isTrue,
      );
      expect(appdata.settings['dataVersion'], 9);
      expect(
        jsonDecode(
          File('${App.dataPath}/appdata.json').readAsStringSync(),
        )['settings']['dataVersion'],
        9,
      );
      allowSecond = true;
      expect(await second.resume!(), DataSyncCommitState.applied);
    },
  );

  test(
    'failed rollback retains both database backups and restores independent cookies',
    () async {
      final previousHistory = HistoryManager.cache;
      final previousFavorites = LocalFavoritesManager.cache;
      final previousCookies = SingleInstanceCookieJar.instance;
      HistoryManager.cache = null;
      LocalFavoritesManager.cache = null;
      SingleInstanceCookieJar.instance = null;
      final history = HistoryManager();
      final favorites = LocalFavoritesManager();
      try {
        for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
          _writeMarker('${App.dataPath}/$name', 'old-$name');
        }
        await history.init();
        await favorites.init();
        SingleInstanceCookieJar('${App.dataPath}/cookie.db');
        final incoming = Directory('${directory.path}/incoming')..createSync();
        _writeMarker('${incoming.path}/history.db', 'new-history');
        _writeMarker('${incoming.path}/cookie.db', 'new-cookie');
        File(
          '${incoming.path}/local_favorite.db',
        ).writeAsBytesSync(List.filled(4096, 42));
        final source = archive(8);
        final zip = ZipFile.open(source.path);
        for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
          zip.addFile(name, '${incoming.path}/$name');
        }
        zip.close();
        final historyError = StateError('history backup restore failed');
        final favoritesError = StateError('favorites backup restore failed');
        final hooks = _ImportIOHooks()
          ..beforeCopy = (source, target) {
            if (p.basename(p.dirname(source)) != 'before') {
              return;
            }
            if (p.basename(source) == 'history.db') throw historyError;
            if (p.basename(source) == 'local_favorite.db') throw favoritesError;
          };
        final error =
            (await _captureImport(
                  IOOverrides.runWithIOOverrides(
                    () => importAppData(source),
                    hooks,
                  ),
                )).error
                as DataSyncImportFailure;
        expect(error.commitState, DataSyncCommitState.recoveryRequired);
        expect(error.cause, isA<SqliteException>());
        expect(
          error.failures.map((failure) => failure.error),
          containsAll([same(historyError), same(favoritesError)]),
        );
        expect(error.resume, isNull);
        expect(
          _readMarker('${error.recoveryPath}/before/history.db'),
          'old-history.db',
        );
        expect(
          _readMarker('${error.recoveryPath}/before/local_favorite.db'),
          'old-local_favorite.db',
        );
        expect(_readMarker('${App.dataPath}/cookie.db'), 'old-cookie.db');
        expect(
          File('${error.recoveryPath}/before/appdata.json').existsSync(),
          isTrue,
        );
        expect(appdata.settings['dataVersion'], 7);
      } finally {
        history.close();
        await favorites.closeAndWait();
        SingleInstanceCookieJar.instance?.dispose();
        HistoryManager.cache = previousHistory;
        LocalFavoritesManager.cache = previousFavorites;
        SingleInstanceCookieJar.instance = previousCookies;
      }
    },
  );

  test('DataSync retains pending edits when archive import skips', () async {
    final sync = _controller(_ArchiveTransfer(archive(7)));
    try {
      expect((await sync.downloadData()).success, isTrue);
      expect(sync.hasPendingChanges, isTrue);
      expect(appdata.searchHistory, ['local']);
    } finally {
      await sync.closeAndWait();
    }
  });

  test('DataSync clears pending only after an applied archive', () async {
    final sync = _controller(_ArchiveTransfer(archive(8)));
    try {
      expect((await sync.downloadData()).success, isTrue);
      expect(sync.hasPendingChanges, isFalse);
      expect(appdata.searchHistory, ['remote']);
    } finally {
      await sync.closeAndWait();
    }
  });

  test(
    'real configure retry finishes imported cleanup without reverting endpoint or importing again',
    () async {
      final remote = _LocalArchiveRemote(archive(8));
      final participant = _RealParticipant();
      final connections = <String>[];
      final transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => App.dataPath,
        openRemote: (connection) {
          connections.add(connection.url);
          return remote;
        },
      );
      final sync = _controller(transfer);
      addTearDown(sync.closeAndWait);
      participant.onNotify = sync.onDataChanged;
      var releaseCleanup = false;
      final hooks = _ImportIOHooks()
        ..beforeDeleteDirectory = (path) {
          if (!releaseCleanup &&
              p
                  .split(path)
                  .any((part) => part.startsWith('.app-data-import-'))) {
            throw FileSystemException('backup cleanup pending', path);
          }
        };
      Future<Res<bool>> configure() => sync.configure(
        config: ['https://new.example.com/dav', 'new', 'secret'],
        excludedFields: '',
        syncMode: DataSyncMode.realtime,
        minutes: 30,
        initialUpload: false,
      );
      final first = await IOOverrides.runWithIOOverrides(configure, hooks);
      expect(first.error, isTrue);
      expect(
        (first.failure as DataSyncFailure).commitState,
        DataSyncCommitState.applied,
      );
      expect(appdata.settings['webdav'], [
        'https://new.example.com/dav',
        'new',
        'secret',
      ]);
      expect(appdata.searchHistory, ['remote']);
      expect(sync.hasPendingChanges, isFalse);
      releaseCleanup = true;
      expect((await configure()).success, isTrue);
      expect(connections, ['https://new.example.com/dav']);
      expect(remote.reads, 1);
      expect(remote.closes, 1);
      expect(participant.imports, 1);
      expect(participant.notifications, 1);
      expect(participant.uploads, 0);
      final saved = jsonDecode(
        File('${App.dataPath}/appdata.json').readAsStringSync(),
      );
      expect(saved['settings']['webdav'], [
        'https://new.example.com/dav',
        'new',
        'secret',
      ]);
    },
  );

  test(
    'real terminal implicit write failure retries persistence without reading or importing again',
    () async {
      final remote = _LocalArchiveRemote(archive(8));
      final participant = _RealParticipant();
      final transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => App.dataPath,
        openRemote: (_) => remote,
      );
      final sync = _controller(transfer);
      addTearDown(sync.closeAndWait);
      participant.onNotify = sync.onDataChanged;
      var failSave = true;
      final saveError = StateError('applied implicit state unavailable');
      final hooks = _ImportIOHooks()
        ..beforeWrite = (path, content) async {
          if (failSave &&
              p.basename(path) == 'implicitData.json.tmp' &&
              content.contains('"commitState":"applied"')) {
            throw saveError;
          }
        };
      final first = await IOOverrides.runWithIOOverrides(
        sync.downloadData,
        hooks,
      );
      expect(first.error, isTrue);
      final failure = first.failure as DataSyncFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(
        failure.failures.map((entry) => entry.error),
        contains(same(saveError)),
      );
      expect(appdata.searchHistory, ['remote']);
      expect(sync.hasPendingChanges, isFalse);
      failSave = false;
      expect((await sync.downloadData()).success, isTrue);
      expect(remote.reads, 1);
      expect(remote.closes, 1);
      expect(participant.imports, 1);
      expect(participant.notifications, 1);
      expect(participant.uploads, 0);
      final implicit = jsonDecode(
        File('${App.dataPath}/implicitData.json').readAsStringSync(),
      );
      expect(implicit['webdavSyncPending'], isFalse);
      expect(implicit.containsKey('webdavSyncOperation'), isFalse);
    },
  );

  test(
    'real local edits during remote close survive while import publication stays suppressed',
    () async {
      appdata.implicitData['webdavSyncPending'] = false;
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final remote = _LocalArchiveRemote(archive(8))
        ..closeGate = release.future;
      final participant = _RealParticipant();
      final transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => App.dataPath,
        openRemote: (_) => remote,
      );
      final sync = _controller(transfer);
      addTearDown(sync.closeAndWait);
      participant.onNotify = sync.onDataChanged;
      final downloading = sync.downloadData();
      await remote.closeStarted.future;
      expect(participant.notifications, 1);
      expect(sync.hasPendingChanges, isFalse);
      sync.onDataChanged();
      expect(sync.hasPendingChanges, isTrue);
      release.complete();
      expect((await downloading).success, isTrue);
      expect(sync.hasPendingChanges, isTrue);
      expect(participant.imports, 1);
      expect(participant.uploads, 0);
      final implicit = jsonDecode(
        File('${App.dataPath}/implicitData.json').readAsStringSync(),
      );
      expect(implicit['webdavSyncPending'], isTrue);
    },
  );

  test(
    'rebuilt application sync consumes the real durable import receipt',
    () async {
      await HistoryManager().init();
      await LocalFavoritesManager().init();
      await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
      addTearDown(() async {
        await HistoryManager().waitForAsyncWrites();
        HistoryManager().close();
        await LocalFavoritesManager().closeAndWait();
      });
      final remote = _LocalArchiveRemote(archive(8));
      appdata.implicitData['webdavSyncPending'] = false;
      appdata.implicitData['webdavSyncMode'] = 'manual';
      var transferCreations = 0;
      DataSyncController create() => createApplicationDataSync(
        transfer: () {
          transferCreations++;
          return createDataSyncTransfer(openRemote: (_) => remote);
        },
      );
      final first = create();
      final failure = StateError('terminal implicit write interrupted');
      final hooks = _ImportIOHooks()
        ..beforeWrite = (path, content) async {
          if (p.basename(path) == 'implicitData.json.tmp' &&
              content.contains('"commitState":"applied"')) {
            throw failure;
          }
        };
      final result = await IOOverrides.runWithIOOverrides(
        first.downloadData,
        hooks,
      );
      expect(result.error, isTrue);
      expect(
        (result.failure as DataSyncFailure).commitState,
        DataSyncCommitState.applied,
      );
      expect(appdata.searchHistory, ['remote']);
      final durable =
          jsonDecode(
                File('${App.dataPath}/implicitData.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final journal = AppDataImportJournal.open(App.dataPath);
      late int commitTime;
      try {
        commitTime = journal.receipts.single.committedAt!;
        expect(
          journal.receipts.single.commitState,
          DataSyncCommitState.applied,
        );
      } finally {
        journal.close();
      }
      await first.closeAndWait();
      // Graceful close writes the current marker. Restore the exact pre-close
      // crash snapshot so this test still exercises interrupted persistence.
      File(
        '${App.dataPath}/implicitData.json',
      ).writeAsStringSync(jsonEncode(durable), flush: true);
      // Reload precisely what survived on disk, discarding the first controller's
      // in-memory continuation. Actual subprocess recovery is tested separately.
      appdata.implicitData
        ..clear()
        ..addAll(durable);
      final second = create();
      try {
        final recovered = await second.downloadData();
        expect(recovered.success, isTrue, reason: recovered.errorMessage);
        expect(transferCreations, 1);
        expect(remote.reads, 1);
        expect(appdata.searchHistory, ['remote']);
        expect(appdata.settings['lastSyncTime'], commitTime);
        // The v4 candidate and applied receipt prove this exact imported
        // content. A restart alone no longer creates a synthetic local edit.
        expect(second.hasPendingChanges, isFalse);
        expect(
          appdata.implicitData.containsKey('webdavSyncOperation'),
          isFalse,
        );
        final acknowledged = AppDataImportJournal.open(App.dataPath);
        try {
          expect(acknowledged.receipts, isEmpty);
        } finally {
          acknowledged.close();
        }
      } finally {
        await second.closeAndWait();
      }
    },
  );

  for (final includeFavorites in [false, true]) {
    for (final scenario in ['applied', 'rolled back', 'local edit']) {
      test(
        'source reload publication with real app observer: $scenario, favorites=$includeFavorites',
        () async {
          final native = Directory(
            'build/windows/x64/runner/Release',
          ).absolute.path;
          DynamicLibrary.open('$native/flutter_windows.dll');
          DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
          App.version = '9.0.0';
          await appdata.saveData(false);
          await appdata.init();
          await HistoryManager().init();
          await LocalFavoritesManager().init();
          await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
          addTearDown(() async {
            await HistoryManager().waitForAsyncWrites();
            HistoryManager().close();
            await LocalFavoritesManager().closeAndWait();
          });
          JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
          final engine = JsEngine();
          await engine.init();
          addTearDown(engine.dispose);
          final sources = ComicSourceManager();
          var sourceNotifications = 0;
          void observeSource() => sourceNotifications++;
          sources.addListener(observeSource);
          addTearDown(() => sources.removeListener(observeSource));

          final snapshot = archive(
            8,
            includeSources: true,
            includeFavorites: includeFavorites,
          );
          final remote = _LocalArchiveRemote(snapshot);
          appdata.implicitData['webdavSyncPending'] = false;
          appdata.implicitData['webdavSyncMode'] = 'manual';
          final sync = createApplicationDataSync(
            transfer: () => createDataSyncTransfer(openRemote: (_) => remote),
          );
          sync.start();
          addTearDown(sync.closeAndWait);
          final entered = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final writeError = FileSystemException(
            'Injected imported metadata failure',
          );
          final hooks = _ImportIOHooks()
            ..beforeWrite = (path, content) async {
              if (p.basename(path) != 'appdata.json.tmp' ||
                  !content.contains('"dataVersion":8')) {
                return;
              }
              if (!entered.isCompleted) entered.complete();
              if (scenario == 'local edit') await release.future;
              if (scenario == 'rolled back') throw writeError;
            };
          final downloading = IOOverrides.runWithIOOverrides(
            sync.downloadData,
            hooks,
          );
          if (scenario == 'local edit') {
            await entered.future;
            // The imported reload was published, but the held metadata write is
            // still in flight. An independent source change must remain local.
            final importPending = sync.hasPendingChanges;
            sources.updateAvailableUpdates({'local-change': '2'});
            // Available-update notifications alone are transient UI state.
            // Queue an actual synchronized write behind the held import.
            final localEdit = appdata.addSearchHistory('local-after-import');
            release.complete();
            await localEdit;
            final result = await downloading;
            await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
            expect(result.success, isTrue, reason: result.errorMessage);
            expect(importPending, isFalse);
            expect(sync.hasPendingChanges, isTrue);
            expect(appdata.searchHistory, contains('local-after-import'));
            expect(sourceNotifications, 2);
          } else {
            final result = await downloading;
            await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
            expect(
              result.success,
              scenario == 'applied',
              reason: result.errorMessage,
            );
            expect(sourceNotifications, scenario == 'rolled back' ? 2 : 1);
            expect(sync.hasPendingChanges, isFalse);
            expect(
              appdata.settings['dataVersion'],
              scenario == 'rolled back' ? 7 : 8,
            );
            if (scenario == 'rolled back') {
              expect(
                (result.failure as DataSyncFailure).commitState,
                DataSyncCommitState.notApplied,
              );
              expect(result.failure?.cause, same(writeError));
            }
          }
          if (includeFavorites && scenario != 'rolled back') {
            expect(
              LocalFavoritesManager().getFolderComics('original').single.id,
              'remote-favorite',
            );
          }
          await sync.flushPersistence();
          expect(remote.reads, 1);
          expect(remote.closes, 1);
        },
        skip: !Platform.isWindows,
      );
    }
  }
}

class _ArchiveTransfer implements DataSyncTransfer {
  const _ArchiveTransfer(this.archive);
  final File archive;

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async =>
      await importSyncAppData(
        archive,
        checkActive: scope.check,
        publishImported: publishImported,
        syncOperationId: syncOperationId,
      ) ==
      DataSyncCommitState.applied;

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) async => throw UnsupportedError('download-only fixture');
}

class _RealParticipant implements DataSyncParticipant {
  int imports = 0;
  int notifications = 0;
  int uploads = 0;
  void Function()? onNotify;
  @override
  int? get version => appdata.settings['dataVersion'] as int?;
  @override
  String get cachePath => App.cachePath;
  @override
  Future<int> prepareUploadVersion() async {
    uploads++;
    throw StateError('Downloaded snapshot must not be uploaded');
  }

  @override
  Future<void> exportData(
    bool excludeFields,
    File destination, {
    String? syncOperationId,
  }) async => throw UnimplementedError();
  @override
  Future<DataSyncCommitState> importData(
    File file, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) {
    imports++;
    return importSyncAppData(
      file,
      checkActive: scope.check,
      publishImported: publishImported,
      syncOperationId: syncOperationId,
    );
  }

  @override
  void notifyImported() {
    notifications++;
    onNotify?.call();
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async {
    appdata.settings['lastSyncTime'] = milliseconds;
    await appdata.saveData(false);
  }
}

class _LocalArchiveRemote implements DataSyncRemote {
  _LocalArchiveRemote(this.archive);
  final File archive;
  int reads = 0;
  int closes = 0;
  final closeStarted = Completer<void>();
  Future<void>? closeGate;
  @override
  Future<List<String>> listNames() async => ['1-8.venera'];
  @override
  Future<void> readToFile(String name, String path) async {
    reads++;
    await archive.copy(path);
  }

  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) async =>
      throw UnimplementedError();
  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async => throw UnimplementedError();
  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async => throw UnimplementedError();
  @override
  Future<void> dispose() async {
    closes++;
    if (!closeStarted.isCompleted) closeStarted.complete();
    await closeGate;
  }
}

DataSyncController _controller(DataSyncTransfer transfer) => DataSyncController(
  preferences: createAppSyncPreferences(appdata),
  transfer: () => transfer,
  saveSettings: () => appdata.saveData(false),
  persistImplicit: appdata.writeImplicitData,
  observeChanges: (_) => () {},
);

Future<({Object error, StackTrace stack})> _captureImport(
  Future<DataSyncCommitState> operation,
) async {
  try {
    await operation;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected import failure');
}

void _writeMarker(String path, String value) {
  final db = sqlite3.open(path);
  try {
    if (p.basename(path) == 'local_favorite.db') {
      final repository = FavoritesRepository(db);
      repository.initializeMetadata();
      repository.createFolder('original');
      repository.addComic(
        'original',
        FavoriteItem(
          id: value,
          name: value,
          author: '',
          coverPath: '',
          type: ComicType.local,
          tags: [],
        ),
        translatedTags: '',
        append: true,
      );
      return;
    }
    db.execute('CREATE TABLE marker (value TEXT NOT NULL)');
    db.execute('INSERT INTO marker VALUES (?)', [value]);
  } finally {
    db.dispose();
  }
}

String _readMarker(String path) {
  final db = sqlite3.open(path);
  try {
    if (p.basename(path) == 'local_favorite.db') {
      return FavoritesRepository(db).getFolderComics('original').single.id;
    }
    return db.select('SELECT value FROM marker').single['value'] as String;
  } finally {
    db.dispose();
  }
}

final class _ImportIOHooks extends IOOverrides {
  Future<void> Function(String path, String content)? beforeWrite;
  void Function(String source, String target)? beforeCopy;
  void Function(String path)? beforeDeleteDirectory;

  @override
  File createFile(String path) => _ImportFile(super.createFile(path), this);

  @override
  Directory createDirectory(String path) =>
      _ImportDirectory(super.createDirectory(path), this);
}

class _ImportFile implements File {
  _ImportFile(this.raw, this.hooks);
  final File raw;
  final _ImportIOHooks hooks;
  @override
  String get path => raw.path;
  @override
  Directory get parent => raw.parent;
  @override
  bool existsSync() => raw.existsSync();
  @override
  Future<bool> exists() => raw.exists();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      raw.readAsString(encoding: encoding);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      raw.readAsStringSync(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => raw.readAsBytes();
  @override
  int lengthSync() => raw.lengthSync();
  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => raw.writeAsBytesSync(bytes, mode: mode, flush: flush);
  @override
  Future<File> copy(String newPath) async {
    hooks.beforeCopy?.call(path, newPath);
    return raw.copy(newPath);
  }

  @override
  String resolveSymbolicLinksSync() => raw.resolveSymbolicLinksSync();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      raw.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      raw.open(mode: mode);
  @override
  Future<File> rename(String newPath) => raw.rename(newPath);
  @override
  File renameSync(String newPath) {
    return raw.renameSync(newPath);
  }

  @override
  void deleteSync({bool recursive = false}) =>
      raw.deleteSync(recursive: recursive);
  @override
  Future<File> delete({bool recursive = false}) async {
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await hooks.beforeWrite?.call(path, contents);
    await raw.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => raw.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImportDirectory implements Directory {
  _ImportDirectory(this.raw, this.hooks);
  final Directory raw;
  final _ImportIOHooks hooks;
  @override
  String get path => raw.path;
  @override
  bool existsSync() => raw.existsSync();
  @override
  Future<bool> exists() => raw.exists();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => raw.listSync(recursive: recursive, followLinks: followLinks);
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => raw.list(recursive: recursive, followLinks: followLinks);
  @override
  Directory renameSync(String newPath) => raw.renameSync(newPath);
  @override
  String resolveSymbolicLinksSync() => raw.resolveSymbolicLinksSync();
  @override
  void deleteSync({bool recursive = false}) =>
      raw.deleteSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _ImportDirectory(await raw.createTemp(prefix), hooks);
  @override
  Future<Directory> create({bool recursive = false}) =>
      raw.create(recursive: recursive);
  @override
  void createSync({bool recursive = false}) =>
      raw.createSync(recursive: recursive);
  @override
  Future<Directory> delete({bool recursive = false}) async {
    hooks.beforeDeleteDirectory?.call(path);
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
