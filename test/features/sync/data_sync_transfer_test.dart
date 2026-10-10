import 'dart:async';
import 'dart:convert';
import 'package:venera_next/network/request_scope.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' as crypto;
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  late Directory directory;
  late Directory journalDirectory;
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
    journalDirectory = Directory.systemTemp.createTempSync('upload-journal-');
    participant = _Participant(directory.path);
    remote = _Remote();
    transfer = WebDavDataSyncTransfer(
      participant: participant,
      uploadJournalPath: () => journalDirectory.path,
      openRemote: (_) => remote,
      now: () => DateTime.fromMillisecondsSinceEpoch(20 * 86400000),
    );
  });
  tearDown(() {
    scope.dispose();
    directory.deleteSync(recursive: true);
    journalDirectory.deleteSync(recursive: true);
  });

  for (final readFails in [false, true]) {
    test(
      'disposed flush joins the transfer commit-time read and follow-up; readFails=$readFails',
      () async {
        remote.names = ['20-8.venera'];
        final gate = Completer<void>();
        final reading = Completer<void>();
        final error = StateError('late commit-time read failed');
        final stack = StackTrace.fromString('commit-time read original stack');
        transfer = WebDavDataSyncTransfer(
          participant: participant,
          uploadJournalPath: () => journalDirectory.path,
          openRemote: (_) => remote,
          readImportCommitTime: (_) async {
            reading.complete();
            await gate.future;
            if (readFails) Error.throwWithStackTrace(error, stack);
            return 12345;
          },
        );
        final settings = <String, dynamic>{
          'webdav': ['https://example.com', '', ''],
        };
        final implicit = <String, dynamic>{'webdavSyncMode': 'manual'};
        final controller = DataSyncController(
          preferences: SyncPreferenceStore(
            readSetting: (key) => settings[key],
            writeSetting: (key, value) => settings[key] = value,
            implicitData: () => implicit,
          ),
          transfer: () => transfer,
          saveSettings: () async {},
          persistImplicit: () {},
          observeChanges: (_) => () {},
        );
        addTearDown(controller.dispose);
        final attempt = controller.downloadData();
        await reading.future;
        controller.dispose();
        var flushed = false;
        final flush = controller.flushPersistence().then((_) => flushed = true);
        await pumpEventQueue();
        expect(flushed, isFalse);
        expect(participant.imports, 1);
        expect(participant.notifications, 0);
        gate.complete();
        final result = await attempt;
        await flush;
        expect(result.error, readFails);
        expect(participant.imports, 1);
        expect(remote.closeCount, 1);
        expect(directory.listSync(), isEmpty);
        if (readFails) {
          final failure = result.failure! as DataSyncFailure;
          expect(
            _stage(failure, 'read import commit time')?.error,
            same(error),
          );
          expect(
            _stage(failure, 'read import commit time')?.stack,
            same(stack),
          );
          expect(implicit['webdavSyncOperation'], isNotNull);
          expect(participant.notifications, 0);
          expect(participant.timeCalls, isEmpty);
        } else {
          expect(implicit['webdavSyncOperation'], isNull);
          expect(participant.notifications, 1);
          expect(participant.timeCalls, [12345]);
        }
      },
    );
  }

  test(
    'download carries operation identity and retries the journal commit time without reimport',
    () async {
      remote.names = ['20-8.venera'];
      var reads = 0;
      transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => journalDirectory.path,
        openRemote: (_) => remote,
        now: () => DateTime.fromMillisecondsSinceEpoch(999999),
        readImportCommitTime: (id) async {
          expect(id, 'operation-id');
          reads++;
          if (reads == 1) throw StateError('journal temporarily unavailable');
          return 12345;
        },
      );
      final captured = await _capture(
        transfer.download(
          connection,
          scope: scope,
          syncOperationId: 'operation-id',
        ),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(participant.importOperationId, 'operation-id');
      expect(participant.imports, 1);
      expect(participant.notifications, 0);
      expect(participant.timeCalls, isEmpty);
      expect(await failure.resume!(scope), DataSyncCommitState.applied);
      expect(reads, 2);
      expect(participant.imports, 1);
      expect(participant.notifications, 1);
      expect(participant.timeCalls, [12345]);
      expect(remote.closeCount, 1);
    },
  );

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
      final checked = expectLater(
        uploading,
        throwsA(isA<DataSyncTransferFailure>()),
      );
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
    'upload preserves naming and retention selection after writing new archive',
    () async {
      remote.names = ['19-4.venera', '20-5.venera', 'notes.txt'];
      await transfer.upload(connection, excludeFields: true, scope: scope);
      expect(participant.version, 8);
      expect(participant.excludeFields, isTrue);
      expect(remote.removed, ['20-5.venera']);
      expect(remote.events, ['write:${remote.written}', 'remove:20-5.venera']);
      expect(remote.written, startsWith('20-8-'));
      expect(remote.bytes, [1, 2, 3]);
      expect(participant.syncTime, 20 * 86400000);
      expect(directory.listSync(), isEmpty);
      expect(remote.closed, isTrue);
    },
  );

  test(
    'unknown upload preserves its owned snapshot and releases remote',
    () async {
      remote.names = ['19-4.venera', '20-5.venera'];
      remote.writeError = StateError('denied');
      await expectLater(
        transfer.upload(connection, excludeFields: false, scope: scope),
        throwsA(
          isA<DataSyncTransferFailure>()
              .having(
                (failure) => failure.commitState,
                'commit state',
                DataSyncCommitState.recoveryRequired,
              )
              .having((failure) => failure.resume, 'resume', isNotNull),
        ),
      );
      expect(participant.syncTime, isNull);
      expect(remote.removed, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(journalDirectory.listSync().whereType<Directory>(), hasLength(1));
      expect(remote.closed, isTrue);
    },
  );

  test(
    'cleanup failure reports failure only after a new recovery point is written',
    () async {
      remote.names = ['19-4.venera', '20-5.venera'];
      remote.removeError = StateError('cannot delete');
      await expectLater(
        transfer.upload(connection, excludeFields: false, scope: scope),
        throwsA(
          isA<DataSyncTransferFailure>().having(
            (failure) => failure.commitState,
            'commit state',
            DataSyncCommitState.applied,
          ),
        ),
      );
      expect(remote.written, startsWith('20-8-'));
      expect(remote.bytes, [1, 2, 3]);
      expect(remote.events, ['write:${remote.written}', 'remove:20-5.venera']);
      expect(participant.syncTime, 20 * 86400000);
      expect(directory.listSync(), isEmpty);
      expect(remote.closed, isTrue);
    },
  );

  test(
    'cancellation after upload acknowledgement preserves old recovery points',
    () async {
      remote.names = ['20-5.venera'];
      remote.afterWrite = scope.cancel;
      await expectLater(
        transfer.upload(connection, excludeFields: false, scope: scope),
        throwsA(
          isA<DataSyncTransferFailure>()
              .having(
                (failure) => failure.commitState,
                'commit state',
                DataSyncCommitState.applied,
              )
              .having(
                (failure) => failure.failures.first.error,
                'cause',
                isA<RequestCancelled>(),
              ),
        ),
      );
      expect(remote.written, startsWith('20-8-'));
      expect(remote.removed, isEmpty);
      expect(participant.syncTime, isNull);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('retention never deletes the newly uploaded name', () async {
    remote.names = ['20-8.venera'];
    await transfer.upload(connection, excludeFields: false, scope: scope);
    expect(remote.written, startsWith('20-8-'));
    expect(remote.removed, ['20-8.venera']);
    expect(remote.removed, isNot(contains(remote.written)));
    expect(participant.syncTime, isNotNull);
  });

  test(
    'overlapping daily and oldest retention candidates are deleted once',
    () async {
      remote.names = [for (var i = 10; i < 20; i++) '20-$i.venera'];
      await transfer.upload(connection, excludeFields: false, scope: scope);
      expect(remote.removed, ['20-10.venera']);
      expect(remote.events, ['write:${remote.written}', 'remove:20-10.venera']);
    },
  );

  test('download selects version 10 after version 9 on the same day', () async {
    participant.version = 9;
    remote.names = ['20-9.venera', '20-10.venera'];
    expect(await transfer.download(connection, scope: scope), isTrue);
    expect(remote.readName, '20-10.venera');
    expect(participant.imports, 1);
  });

  test(
    'retention threshold uses the original filtered listing length',
    () async {
      remote.names = ['9-1.venera', for (var i = 0; i < 9; i++) '19-2.venera'];
      await transfer.upload(connection, excludeFields: false, scope: scope);
      expect(remote.removed, ['9-1.venera']);
    },
  );

  test('download selects the later numeric day', () async {
    remote.names = ['9-100.venera', '10-10.venera'];
    expect(await transfer.download(connection, scope: scope), isTrue);
    expect(remote.readName, '10-10.venera');
  });

  test(
    'retention removes numeric oldest and daily candidates independent of listing order',
    () async {
      remote.names = [
        '20-10.venera',
        '10-1.venera',
        '9-100.venera',
        '20-9.venera',
        for (var day = 11; day < 17; day++) '$day-1.venera',
      ];
      await transfer.upload(connection, excludeFields: false, scope: scope);
      expect(remote.removed, ['20-9.venera', '9-100.venera']);
      expect(remote.written, startsWith('20-8-'));
    },
  );

  test('unversioned legacy archive remains downloadable', () async {
    remote.names = ['backup.venera'];
    expect(await transfer.download(connection, scope: scope), isTrue);
    expect(remote.readName, 'backup.venera');
    expect(participant.imports, 1);
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

  test('forced download applies an unchanged remote version', () async {
    remote.names = ['20-7.venera'];
    expect(
      await transfer.download(connection, scope: scope, force: true),
      isTrue,
    );
    expect(remote.readName, '20-7.venera');
    expect(participant.imports, 1);
  });

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

  test(
    'acknowledged upload resumes retention with a new remote without reuploading',
    () async {
      remote.names = ['19-4.venera', '20-5.venera'];
      remote.removeError = StateError('retention unavailable');
      final resumedRemote = _Remote()
        ..names = ['19-4.venera', '20-5.venera', '20-8.venera'];
      var connections = 0;
      transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => journalDirectory.path,
        openRemote: (_) => connections++ == 0 ? remote : resumedRemote,
        now: () => DateTime.fromMillisecondsSinceEpoch(20 * 86400000),
      );
      final captured = await _capture(
        transfer.upload(connection, excludeFields: false, scope: scope),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(
        _stage(failure, 'retention 20-5.venera')?.error,
        same(remote.removeError),
      );
      final retryScope = RequestScope();
      addTearDown(retryScope.dispose);
      expect(await failure.resume!(retryScope), DataSyncCommitState.applied);
      expect(connections, 2);
      expect(participant.version, 8);
      expect(participant.exportCount, 1);
      expect(resumedRemote.events, ['remove:20-5.venera']);
      expect(resumedRemote.written, isNull);
      expect(resumedRemote.readPath, isNull);
      expect(resumedRemote.closeCount, 1);
      expect(remote.closeCount, 1);
      expect(participant.syncTime, 20 * 86400000);
      // The same receipt is harmless after its remaining work finishes.
      expect(await failure.resume!(retryScope), DataSyncCommitState.applied);
      expect(connections, 2);
      expect(participant.timeCalls, hasLength(1));
    },
  );

  test(
    'acknowledged upload timestamp retry retains the original commit time',
    () async {
      participant.timeError = StateError('settings unavailable');
      var now = DateTime.fromMillisecondsSinceEpoch(20 * 86400000);
      transfer = WebDavDataSyncTransfer(
        participant: participant,
        uploadJournalPath: () => journalDirectory.path,
        openRemote: (_) => remote,
        now: () => now,
      );
      final captured = await _capture(
        transfer.upload(connection, excludeFields: false, scope: scope),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(
        _stage(failure, 'record upload sync time')?.error,
        same(participant.timeError),
      );
      participant.timeError = null;
      now = now.add(const Duration(days: 1));
      expect(await failure.resume!(scope), DataSyncCommitState.applied);
      expect(participant.timeCalls, [20 * 86400000, 20 * 86400000]);
      expect(participant.version, 8);
      expect(participant.exportCount, 1);
      expect(
        remote.events.where((event) => event.startsWith('write:')),
        hasLength(1),
      );
      expect(remote.closeCount, 2);
    },
  );

  test(
    'applied import retries only failed notifications then timestamp',
    () async {
      remote.names = ['20-8.venera'];
      participant.notifyError = StateError('notification failed');
      var publications = 0;
      var publishing = false;
      void publish(void Function() notify) {
        publications++;
        publishing = true;
        try {
          notify();
        } finally {
          publishing = false;
        }
      }

      final captured = await _capture(
        transfer
            .download(connection, scope: scope, publishImported: publish)
            .then((_) {}),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(
        _stage(failure, 'notify imported')?.error,
        same(participant.notifyError),
      );
      expect(publishing, isFalse);
      expect(publications, 1);
      participant.notifyError = null;
      participant.timeError = StateError('time failed');
      final second = await _capture(failure.resume!(scope).then((_) {}));
      final remaining = second.error as DataSyncTransferFailure;
      expect(remaining.commitState, DataSyncCommitState.applied);
      expect(
        _stage(remaining, 'record sync time')?.error,
        same(participant.timeError),
      );
      expect(publications, 2);
      participant.timeError = null;
      expect(await remaining.resume!(scope), DataSyncCommitState.applied);
      expect(publications, 2);
      expect(participant.notifications, 2);
      expect(participant.imports, 1);
      expect(remote.closeCount, 1);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'importer post-commit failure still publishes and retains its commit receipt',
    () async {
      remote.names = ['20-8.venera'];
      final error = FileSystemException('import backup deletion failed');
      final stack = StackTrace.fromString('import cleanup stack');
      participant.importError = DataSyncFailure(
        commitState: DataSyncCommitState.applied,
        failures: [
          (stage: 'import backup cleanup', error: error, stack: stack),
        ],
        recoveryPath: 'retained-import-backup',
      );
      participant.importStack = stack;
      final captured = await _capture(
        transfer.download(connection, scope: scope).then((_) {}),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(failure.recoveryPath, 'retained-import-backup');
      expect(failure.failures.single.error, same(error));
      expect(failure.failures.single.stack, same(stack));
      expect(participant.notifications, 1);
      expect(participant.syncTime, 20 * 86400000);
      expect(await failure.resume!(scope), DataSyncCommitState.applied);
      expect(participant.imports, 1);
      expect(participant.notifications, 1);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'import cleanup retry retains failures while notifications and time complete',
    () async {
      remote.names = ['20-8.venera'];
      final cleanupError = FileSystemException('import cleanup unavailable');
      final cleanupStack = StackTrace.fromString(
        'original import cleanup stack',
      );
      var failCleanup = true;
      var cleanupAttempts = 0;
      Future<DataSyncCommitState> cleanup() async {
        cleanupAttempts++;
        if (failCleanup) {
          throw DataSyncImportFailure(
            commitState: DataSyncCommitState.applied,
            failures: [
              (
                stage: 'import backup cleanup',
                error: cleanupError,
                stack: cleanupStack,
              ),
            ],
            recoveryPath: 'retained-backup',
            resume: cleanup,
          );
        }
        return DataSyncCommitState.applied;
      }

      participant.importError = DataSyncImportFailure(
        commitState: DataSyncCommitState.applied,
        failures: [
          (
            stage: 'import backup cleanup',
            error: cleanupError,
            stack: cleanupStack,
          ),
        ],
        recoveryPath: 'retained-backup',
        resume: cleanup,
      );
      participant.notifyError = StateError('notification unavailable');
      final first = await _capture(
        transfer.download(connection, scope: scope).then((_) {}),
      );
      final receipt = first.error as DataSyncTransferFailure;
      expect(receipt.failures, hasLength(2));
      expect(cleanupAttempts, 0);
      participant.notifyError = null;
      final second = await _capture(receipt.resume!(scope).then((_) {}));
      final remaining = second.error as DataSyncTransferFailure;
      expect(remaining.commitState, DataSyncCommitState.applied);
      expect(remaining.failures.single.error, same(cleanupError));
      expect(remaining.failures.single.stack, same(cleanupStack));
      expect(remaining.recoveryPath, 'retained-backup');
      expect(cleanupAttempts, 1);
      expect(participant.notifications, 2);
      expect(participant.syncTime, 20 * 86400000);
      failCleanup = false;
      expect(await remaining.resume!(scope), DataSyncCommitState.applied);
      expect(await remaining.resume!(scope), DataSyncCommitState.applied);
      expect(cleanupAttempts, 2);
      expect(participant.notifications, 2);
      expect(participant.timeCalls, hasLength(1));
      expect(participant.imports, 1);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'incomplete import recovery has no resumable transfer and never publishes',
    () async {
      remote.names = ['20-8.venera'];
      final error = StateError('rollback failed');
      final stack = StackTrace.fromString('rollback stack');
      participant.importError = DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        failures: [(stage: 'rollback', error: error, stack: stack)],
        recoveryPath: 'retained-import-backup',
      );
      final captured = await _capture(
        transfer.download(connection, scope: scope).then((_) {}),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(failure.commitState, DataSyncCommitState.recoveryRequired);
      expect(failure.resume, isNull);
      expect(failure.recoveryPath, 'retained-import-backup');
      expect(failure.failures.single.error, same(error));
      expect(participant.notifications, 0);
      expect(participant.timeCalls, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(remote.closeCount, 1);
    },
  );

  Future<void> runTransfer(bool download) async {
    if (download) {
      await transfer.download(connection, scope: scope);
    } else {
      await transfer.upload(connection, excludeFields: false, scope: scope);
    }
  }

  for (final closeFails in [false, true]) {
    test(
      'upload cancellation joins native close and preserves late diagnostics; closeFails=$closeFails',
      () async {
        final request = Completer<void>();
        final closing = Completer<void>();
        final error = StateError('late listing failed');
        final stack = StackTrace.fromString('late listing original stack');
        final closeError = StateError('late native close failed');
        final closeStack = StackTrace.fromString('native close original stack');
        remote.listGate = request.future;
        remote.closeGate = closing.future;
        if (closeFails) {
          remote.closeError = closeError;
          remote.closeStack = closeStack;
        }
        var finished = false;
        final attempt =
            _capture(
              transfer.upload(connection, excludeFields: false, scope: scope),
            ).then((value) {
              finished = true;
              return value;
            });
        await remote.listStarted.future;
        scope.cancel();
        await remote.closeStarted.future;
        expect(remote.closeCount, 1);
        expect(journalDirectory.listSync().whereType<Directory>(), isNotEmpty);
        request.completeError(error, stack);
        await pumpEventQueue();
        expect(finished, isFalse);
        closing.complete();
        final failure = (await attempt).error as DataSyncTransferFailure;
        expect(
          failure.failures.any(
            (e) => identical(e.error, error) && identical(e.stack, stack),
          ),
          isTrue,
        );
        if (closeFails) {
          expect(
            failure.failures.any(
              (e) =>
                  identical(e.error, closeError) &&
                  identical(e.stack, closeStack),
            ),
            isTrue,
          );
        }
        expect(remote.closeCount, 1);
        expect(remote.written, isNull);
        expect(failure.resume, isNotNull);
        expect(journalDirectory.listSync().whereType<Directory>(), isNotEmpty);
      },
    );
  }

  test(
    'upload waits for native close before removing its journal snapshot',
    () async {
      final closing = Completer<void>();
      remote.closeGate = closing.future;
      var finished = false;
      final attempt = transfer
          .upload(connection, excludeFields: false, scope: scope)
          .then((_) => finished = true);
      await remote.closeStarted.future;
      expect(journalDirectory.listSync().whereType<Directory>(), hasLength(1));
      await pumpEventQueue();
      expect(finished, isFalse);
      closing.complete();
      await attempt;
      expect(journalDirectory.listSync().whereType<Directory>(), isEmpty);
      expect(await transfer.listTerminalUploadOperations(), isEmpty);
      expect(remote.closeCount, 1);
    },
  );

  test(
    'upload owned snapshot cleanup retries without re-exporting or repeating timestamp',
    () async {
      var attempts = 0;
      var fail = true;
      final overrides = _UploadCleanupOverrides(journalDirectory.path, () {
        attempts++;
        if (fail) throw FileSystemException('snapshot cleanup unavailable');
      });
      final captured = await _capture(
        IOOverrides.runWithIOOverrides(
          () => transfer.upload(connection, excludeFields: false, scope: scope),
          overrides,
        ),
      );
      final failure = captured.error as DataSyncTransferFailure;
      expect(
        failure.commitState,
        DataSyncCommitState.applied,
        reason: failure.message,
      );
      expect(journalDirectory.listSync().whereType<Directory>(), hasLength(1));
      fail = false;
      expect(
        await IOOverrides.runWithIOOverrides(
          () => failure.resume!(scope),
          overrides,
        ),
        DataSyncCommitState.applied,
      );
      expect(journalDirectory.listSync().whereType<Directory>(), isEmpty);
      expect(attempts, 2);
      expect(participant.exportCount, 1);
      expect(participant.timeCalls, hasLength(1));
    },
  );

  // Upload snapshot cleanup is covered by the journal executor's matrix;
  // this matrix retains the download temporary-directory ownership checks.
  for (final download in [true]) {
    final direction = download ? 'download' : 'upload';

    test(
      '$direction committed file cleanup retries without repeating business work',
      () async {
        remote.names = ['20-8.venera'];
        var attempts = 0;
        var fail = true;
        final captured = await _capture(
          IOOverrides.runWithIOOverrides(
            () => runTransfer(download),
            _CleanupOverrides(directory.path, () {
              attempts++;
              if (fail) throw FileSystemException('cleanup unavailable');
            }),
          ),
        );
        final failure = captured.error as DataSyncTransferFailure;
        expect(failure.commitState, DataSyncCommitState.applied);
        expect(directory.listSync(), isNotEmpty);
        fail = false;
        expect(await failure.resume!(scope), DataSyncCommitState.applied);
        expect(directory.listSync(), isEmpty);
        expect(attempts, 2);
        expect(remote.closeCount, 1);
        expect(participant.timeCalls, hasLength(1));
        expect(participant.imports, download ? 1 : 0);
        expect(participant.exportCount, download ? 0 : 1);
      },
    );

    test(
      '$direction terminal close diagnostic is reported once without replaying close',
      () async {
        remote.names = ['20-8.venera'];
        final error = StateError('native close failed');
        remote.closeError = error;
        final captured = await _capture(runTransfer(download));
        final failure = captured.error as DataSyncTransferFailure;
        expect(failure.commitState, DataSyncCommitState.applied);
        expect(_stage(failure, 'remote close')?.error, same(error));
        expect(await failure.resume!(scope), DataSyncCommitState.applied);
        expect(remote.closeCount, 1);
        expect(participant.timeCalls, hasLength(1));
        expect(participant.imports, download ? 1 : 0);
        expect(participant.exportCount, download ? 0 : 1);
      },
    );

    test(
      '$direction waits for delayed remote close before deleting files or completing',
      () async {
        remote.names = ['20-8.venera'];
        final close = Completer<void>();
        remote.closeGate = close.future;
        var finished = false;
        final operation = runTransfer(download).then((_) => finished = true);
        await remote.closeStarted.future;
        expect(directory.listSync(), isNotEmpty);
        expect(remote.closeFinished, isFalse);
        await pumpEventQueue();
        expect(finished, isFalse);
        expect(directory.listSync(), isNotEmpty);
        close.complete();
        await operation;
        expect(remote.closeFinished, isTrue);
        expect(remote.closeCount, 1);
        expect(directory.listSync(), isEmpty);
      },
    );

    test(
      '$direction cancellation and finally join one close after original request settles',
      () async {
        remote.names = ['20-8.venera'];
        final request = Completer<void>();
        final close = Completer<void>();
        remote.closeGate = close.future;
        if (download) {
          remote.readGate = request.future;
        } else {
          remote.listGate = request.future;
        }
        var settled = false;
        final captured = _capture(runTransfer(download)).then((failure) {
          settled = true;
          return failure;
        });
        await (download
            ? remote.readStarted.future
            : remote.listStarted.future);
        scope.cancel();
        await remote.closeStarted.future;
        expect(remote.closeCount, 1);
        expect(settled, isFalse);
        expect(directory.listSync(), isNotEmpty);
        request.complete();
        await pumpEventQueue();
        expect(settled, isFalse);
        expect(directory.listSync(), isNotEmpty);
        close.complete();
        final failure = await captured;
        expect(failure.error, isA<RequestCancelled>());
        expect(remote.closeCount, 1);
        expect(participant.imports, 0);
        expect(participant.notifications, 0);
        expect(participant.syncTime, isNull);
        expect(directory.listSync(), isEmpty);
      },
    );

    test(
      '$direction remote-close failure still cleans files and retains close diagnostics',
      () async {
        remote.names = ['20-8.venera'];
        final error = StateError('remote close failed');
        final stack = StackTrace.fromString('original remote close stack');
        remote.closeError = error;
        remote.closeStack = stack;
        final failure = await _capture(runTransfer(download));
        final cleanup = failure.error as DataSyncTransferFailure;
        expect(_stage(cleanup, 'transfer')?.error, isNull);
        expect(_stage(cleanup, 'remote close')?.error, same(error));
        expect(
          _stage(cleanup, 'remote close')?.stack.toString(),
          stack.toString(),
        );
        expect(_stage(cleanup, 'file cleanup')?.error, isNull);
        expect(failure.stack.toString(), stack.toString());
        expect(directory.listSync(), isEmpty);
        expect(remote.closeCount, 1);
      },
    );

    for (final closeFails in [false, true]) {
      test(
        '$direction late request failure keeps its identity after cancellation; closeFails=$closeFails',
        () async {
          remote.names = ['20-8.venera'];
          final request = Completer<void>();
          final error = StateError('late request failure');
          final stack = StackTrace.fromString('original late request stack');
          final closeError = StateError('early close failure');
          final closeStack = StackTrace.fromString(
            'original early close stack',
          );
          if (download) {
            remote.readGate = request.future;
          } else {
            remote.listGate = request.future;
          }
          if (closeFails) {
            remote.closeError = closeError;
            remote.closeStack = closeStack;
          }
          var settled = false;
          final captured = _capture(runTransfer(download)).then((failure) {
            settled = true;
            return failure;
          });
          await (download
              ? remote.readStarted.future
              : remote.listStarted.future);
          scope.cancel();
          await remote.closeStarted.future;
          // A failed close is observed while the original request is still
          // pending, rather than becoming an unhandled asynchronous error.
          await pumpEventQueue();
          expect(settled, isFalse);
          expect(directory.listSync(), isNotEmpty);
          request.completeError(error, stack);
          final failure = await captured;
          expect(failure.stack.toString(), stack.toString());
          if (closeFails) {
            final cleanup = failure.error as DataSyncTransferFailure;
            expect(_stage(cleanup, 'transfer')?.error, same(error));
            expect(
              _stage(cleanup, 'transfer')?.stack.toString(),
              stack.toString(),
            );
            expect(_stage(cleanup, 'remote close')?.error, same(closeError));
            expect(
              _stage(cleanup, 'remote close')?.stack.toString(),
              closeStack.toString(),
            );
            expect(_stage(cleanup, 'file cleanup')?.error, isNull);
          } else {
            expect(failure.error, same(error));
          }
          expect(participant.imports, 0);
          expect(participant.syncTime, isNull);
          expect(remote.closeCount, 1);
          expect(directory.listSync(), isEmpty);
        },
      );
    }

    test(
      '$direction retains request, remote-close and real-file cleanup failures together',
      () async {
        remote.names = ['20-8.venera'];
        final request = Completer<void>();
        final error = StateError('original request failed');
        final stack = StackTrace.fromString('original request stack');
        final closeError = StateError('remote disposal failed');
        final closeStack = StackTrace.fromString('remote disposal stack');
        final fileError = FileSystemException('cannot remove owned archive');
        final fileStack = StackTrace.fromString('owned file cleanup stack');
        remote.closeError = closeError;
        remote.closeStack = closeStack;
        if (download) {
          remote.readGate = request.future;
        } else {
          remote.listGate = request.future;
        }
        var cleanupAttempts = 0;
        final overrides = _CleanupOverrides(directory.path, () {
          cleanupAttempts++;
          expect(remote.closeFinished, isTrue);
          Error.throwWithStackTrace(fileError, fileStack);
        });
        final captured = _capture(
          IOOverrides.runWithIOOverrides(
            () => runTransfer(download),
            overrides,
          ),
        );
        await (download
            ? remote.readStarted.future
            : remote.listStarted.future);
        scope.cancel();
        await remote.closeStarted.future;
        await pumpEventQueue();
        request.completeError(error, stack);
        final failure = await captured;
        final cleanup = failure.error as DataSyncTransferFailure;
        expect(_stage(cleanup, 'transfer')?.error, same(error));
        expect(_stage(cleanup, 'transfer')?.stack.toString(), stack.toString());
        expect(_stage(cleanup, 'remote close')?.error, same(closeError));
        expect(
          _stage(cleanup, 'remote close')?.stack.toString(),
          closeStack.toString(),
        );
        expect(_stage(cleanup, 'file cleanup')?.error, same(fileError));
        expect(
          _stage(cleanup, 'file cleanup')?.stack.toString(),
          fileStack.toString(),
        );
        expect(failure.stack.toString(), stack.toString());
        expect(cleanupAttempts, 1);
        expect(directory.listSync(), isNotEmpty);
        expect(participant.syncTime, isNull);
        expect(remote.closeCount, 1);
      },
    );

    test(
      '$direction file-only cleanup failure keeps its own error and stack',
      () async {
        remote.names = ['20-8.venera'];
        final error = FileSystemException('cannot remove file');
        final stack = StackTrace.fromString('file-only cleanup stack');
        final captured = await _capture(
          IOOverrides.runWithIOOverrides(
            () => runTransfer(download),
            _CleanupOverrides(directory.path, () {
              expect(remote.closeFinished, isTrue);
              Error.throwWithStackTrace(error, stack);
            }),
          ),
        );
        final cleanup = captured.error as DataSyncTransferFailure;
        expect(_stage(cleanup, 'transfer')?.error, isNull);
        expect(_stage(cleanup, 'remote close')?.error, isNull);
        expect(_stage(cleanup, 'file cleanup')?.error, same(error));
        expect(
          _stage(cleanup, 'file cleanup')?.stack.toString(),
          stack.toString(),
        );
        expect(captured.stack.toString(), stack.toString());
        expect(remote.closeCount, 1);
      },
    );
  }

  test(
    'synchronous close throw becomes one observed Future without losing cancellation',
    () async {
      remote.names = ['20-8.venera'];
      final request = Completer<void>();
      remote.readGate = request.future;
      final error = StateError('synchronous disposal failure');
      final stack = StackTrace.fromString('synchronous disposal stack');
      remote.synchronousCloseError = error;
      remote.closeStack = stack;
      final captured = _capture(runTransfer(true));
      await remote.readStarted.future;
      scope.cancel();
      await remote.closeStarted.future;
      await pumpEventQueue();
      request.complete();
      final failure = await captured;
      final cleanup = failure.error as DataSyncTransferFailure;
      expect(_stage(cleanup, 'transfer')?.error, isA<RequestCancelled>());
      expect(_stage(cleanup, 'remote close')?.error, same(error));
      expect(
        _stage(cleanup, 'remote close')?.stack.toString(),
        stack.toString(),
      );
      expect(_stage(cleanup, 'file cleanup')?.error, isNull);
      expect(remote.closeCount, 1);
      expect(participant.syncTime, isNull);
      expect(directory.listSync(), isEmpty);
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
  StackTrace? importStack;
  Object? notifyError;
  Object? timeError;
  int exportCount = 0;
  final timeCalls = <int>[];
  Future<void>? importGate;
  final importStarted = Completer<void>();
  int imports = 0;
  int notifications = 0;
  int? syncTime;
  String? importOperationId;

  @override
  Future<int> prepareUploadVersion() async => ++version;
  @override
  Future<void> exportData(
    bool excludeFields,
    File destination, {
    String? syncOperationId,
  }) async {
    exportCount++;
    this.excludeFields = excludeFields;
    await destination.writeAsBytes([1, 2, 3]);
  }

  @override
  Future<DataSyncCommitState> importData(
    File file, {
    required RequestScope scope,
    bool force = false,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async {
    scope.check();
    expect(await file.readAsBytes(), [4, 5]);
    scope.check();
    imports++;
    importOperationId = syncOperationId;
    importStarted.complete();
    await importGate;
    final error = importError;
    if (error != null) {
      Error.throwWithStackTrace(error, importStack ?? StackTrace.current);
    }
    return applied
        ? DataSyncCommitState.applied
        : DataSyncCommitState.notApplied;
  }

  @override
  void notifyImported() {
    expect(imports, 1);
    notifications++;
    if (notifyError case final error?) throw error;
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async {
    timeCalls.add(milliseconds);
    if (timeError case final error?) throw error;
    syncTime = milliseconds;
  }
}

class _Remote implements DataSyncRemote {
  List<String> names = [];
  final removed = <String>[];
  final events = <String>[];
  final stored = <String, Uint8List>{};
  Object? removeError;
  void Function()? afterWrite;
  String? written;
  Uint8List? bytes;
  String? readPath;
  String? readName;
  Object? writeError;
  bool closed = false;
  bool closeFinished = false;
  int closeCount = 0;
  Future<void>? closeGate;
  Object? closeError;
  Object? synchronousCloseError;
  StackTrace? closeStack;
  final closeStarted = Completer<void>();
  Future<void>? readGate;
  final readStarted = Completer<void>();
  Future<void>? listGate;
  final listStarted = Completer<void>();
  @override
  Future<List<String>> listNames() async {
    if (!listStarted.isCompleted) listStarted.complete();
    await listGate;
    return List.of(names);
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    events.add('remove:$name');
    final error = removeError;
    if (error != null) throw error;
    removed.add(name);
    names.remove(name);
    stored.remove(name);
    return DataSyncArchiveRemoveResult.removed;
  }

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    events.add('write:$name');
    final error = writeError;
    if (error != null) throw error;
    if (stored.containsKey(name) || names.contains(name)) {
      return DataSyncArchiveCreateResult.preconditionFailed;
    }
    final bytes = await source.readAsBytes();
    written = name;
    this.bytes = bytes;
    stored[name] = bytes;
    names.add(name);
    afterWrite?.call();
    return DataSyncArchiveCreateResult.created;
  }

  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) async {
    final bytes =
        stored[name] ?? (names.contains(name) ? Uint8List.fromList([7]) : null);
    if (bytes == null) return const DataSyncArchiveMissing();
    return DataSyncArchivePresent(
      sha256: crypto.sha256.convert(bytes).toString(),
      length: bytes.length,
      strongEtag: '"${crypto.sha256.convert(bytes)}"',
    );
  }

  @override
  Future<void> readToFile(String name, String path) async {
    readName = name;
    readPath = path;
    readStarted.complete();
    await readGate;
    await File(path).writeAsBytes([4, 5]);
  }

  @override
  Future<void> dispose() {
    closed = true;
    closeCount++;
    if (!closeStarted.isCompleted) closeStarted.complete();
    if (synchronousCloseError case final error?) {
      Error.throwWithStackTrace(error, closeStack ?? StackTrace.current);
    }
    return () async {
      await closeGate;
      closeFinished = true;
      if (closeError case final error?) {
        Error.throwWithStackTrace(error, closeStack ?? StackTrace.current);
      }
    }();
  }
}

Future<({Object error, StackTrace stack})> _capture(
  Future<void> operation,
) async {
  try {
    await operation;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected transfer failure');
}

final class _CleanupOverrides extends IOOverrides {
  _CleanupOverrides(this.root, this.failDelete);
  final String root;
  final void Function() failDelete;

  @override
  File createFile(String path) {
    final raw = super.createFile(path);
    return p.equals(p.normalize(path), p.join(root, 'export.venera'))
        ? _CleanupFile(raw, failDelete)
        : raw;
  }

  @override
  Directory createDirectory(String path) {
    final raw = super.createDirectory(path);
    return p.equals(p.normalize(path), p.normalize(root))
        ? _CleanupRoot(raw, failDelete)
        : raw;
  }
}

class _CleanupFile implements File {
  _CleanupFile(this.raw, this.failDelete);
  final File raw;
  final void Function() failDelete;
  @override
  String get path => raw.path;
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      raw.openRead(start, end);
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => raw.openWrite(mode: mode, encoding: encoding);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      raw.open(mode: mode);
  @override
  bool existsSync() => raw.existsSync();
  @override
  String resolveSymbolicLinksSync() => raw.resolveSymbolicLinksSync();
  @override
  Future<String> resolveSymbolicLinks() => raw.resolveSymbolicLinks();
  @override
  Future<int> length() => raw.length();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await raw.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  Future<Uint8List> readAsBytes() => raw.readAsBytes();
  @override
  Future<bool> exists() => raw.exists();
  @override
  Future<File> delete({bool recursive = false}) async {
    failDelete();
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UploadCleanupOverrides extends IOOverrides {
  _UploadCleanupOverrides(this.root, this.failDelete);
  final String root;
  final void Function() failDelete;
  @override
  File createFile(String path) {
    final raw = super.createFile(path);
    return p.isWithin(root, path) && p.basename(path) == 'snapshot.venera'
        ? _CleanupFile(raw, failDelete)
        : raw;
  }
}

class _CleanupRoot implements Directory {
  _CleanupRoot(this.raw, this.failDelete);
  final Directory raw;
  final void Function() failDelete;
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _CleanupDirectory(await raw.createTemp(prefix), failDelete);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CleanupDirectory implements Directory {
  _CleanupDirectory(this.raw, this.failDelete);
  final Directory raw;
  final void Function() failDelete;
  @override
  String get path => raw.path;
  @override
  Future<bool> exists() => raw.exists();
  @override
  Future<Directory> delete({bool recursive = false}) async {
    expect(recursive, isTrue);
    failDelete();
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DataSyncDiagnostic? _stage(DataSyncFailure failure, String stage) =>
    failure.failures.where((failure) => failure.stage == stage).firstOrNull;
