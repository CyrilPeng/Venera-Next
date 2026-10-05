import '../../support/data_sync_fixture.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

void main() {
  late SyncTestFixture fixture;
  setUp(() {
    fixture = SyncTestFixture();
    Log.isMuted = true;
  });

  tearDown(() {
    Log.clear();
    Log.isMuted = false;
    fixture.disposeController();
  });

  test(
    'uploadData coalesces concurrent uploads into one pending task',
    () async {
      final uploads = <Completer<Res<bool>>>[];
      fixture.transfer.onUpload = () {
        final completer = Completer<Res<bool>>();
        uploads.add(completer);
        return completer.future;
      };

      final sync = fixture.controller;
      final first = sync.uploadData();
      final second = sync.uploadData();
      final third = sync.uploadData();
      var waitCompleted = false;
      final waitFuture = sync.waitForUpload().then((_) {
        waitCompleted = true;
      });
      await pumpEventQueue();

      expect(sync.isUploading, isTrue);
      expect(uploads, hasLength(1));
      expect(waitCompleted, isFalse);

      uploads.first.complete(const Res(true));
      await pumpEventQueue();

      expect(sync.isUploading, isTrue);
      expect(uploads, hasLength(2));
      expect(waitCompleted, isFalse);

      uploads[1].complete(const Res(true));
      final results = await Future.wait([first, second, third]);
      await waitFuture;

      expect(results.every((result) => result.success), isTrue);
      expect(uploads, hasLength(2));
      expect(sync.isUploading, isFalse);
      expect(waitCompleted, isTrue);
    },
  );

  test('downloadData waits for an active upload before starting', () async {
    final upload = Completer<Res<bool>>();
    var downloadCount = 0;
    fixture.transfer.onUpload = () => upload.future;
    fixture.transfer.onDownload = () async {
      downloadCount++;
      return const Res(true);
    };

    final sync = fixture.controller;
    final uploadFuture = sync.uploadData();
    final downloadFuture = sync.downloadData();

    expect(sync.isUploading, isTrue);
    expect(downloadCount, 0);

    upload.complete(const Res(true));

    final downloadResult = await downloadFuture;
    final uploadResult = await uploadFuture;

    expect(uploadResult.success, isTrue);
    expect(downloadResult.success, isTrue);
    expect(downloadCount, 1);
    expect(sync.isUploading, isFalse);
    expect(sync.isDownloading, isFalse);
  });

  test('waitForDownload waits for a pending download task', () async {
    final upload = Completer<Res<bool>>();
    final download = Completer<Res<bool>>();
    var downloadStarted = false;
    fixture.transfer.onUpload = () => upload.future;
    fixture.transfer.onDownload = () {
      downloadStarted = true;
      return download.future;
    };

    final sync = fixture.controller;
    final uploadFuture = sync.uploadData();
    final downloadFuture = sync.downloadData();
    var waitCompleted = false;
    final waitFuture = sync.waitForDownload().then((_) {
      waitCompleted = true;
    });

    expect(sync.isUploading, isTrue);
    expect(sync.isDownloading, isFalse);
    expect(downloadStarted, isFalse);
    expect(waitCompleted, isFalse);

    upload.complete(const Res(true));
    await pumpEventQueue();

    expect(downloadStarted, isTrue);
    expect(sync.isDownloading, isTrue);
    expect(waitCompleted, isFalse);

    download.complete(const Res(true));
    await Future.wait([uploadFuture, downloadFuture, waitFuture]);

    expect(waitCompleted, isTrue);
    expect(sync.isDownloading, isFalse);
  });

  test('uploadData records failed results in status snapshot', () async {
    fixture.transfer.onUpload = () async {
      return const Res.error('upload failed');
    };

    final sync = fixture.controller;
    final result = await sync.uploadData();

    expect(result.error, isTrue);
    expect(result.errorMessage, 'upload failed');
    expect(sync.lastError, 'upload failed');
    expect(sync.statusSnapshot.lastError, 'upload failed');
    expect(sync.isUploading, isFalse);
  });

  test(
    'dispose finishes active transfer without starting queued work or notifying',
    () async {
      final gate = Completer<Res<bool>>();
      var uploads = 0;
      fixture.transfer.onUpload = () {
        uploads++;
        return gate.future;
      };
      final sync = fixture.controller;
      var notifications = 0;
      sync.addListener(() => notifications++);
      final active = sync.uploadData();
      final queued = sync.uploadData();
      await pumpEventQueue();
      sync.dispose();
      final before = notifications;
      gate.complete(const Res(true));
      expect((await active).success, isTrue);
      expect((await queued).error, isTrue);
      expect(uploads, 1);
      expect(notifications, before);
      expect((await sync.downloadData()).error, isTrue);
    },
  );

  test('downloadData converts thrown errors into failed results', () async {
    fixture.transfer.onDownload = () async {
      throw StateError('download failed');
    };

    final sync = fixture.controller;
    final result = await sync.downloadData();

    expect(result.error, isTrue);
    expect(result.errorMessage, contains('download failed'));
    expect(sync.lastError, result.errorMessage);
    expect(sync.isDownloading, isFalse);
  });

  for (final download in [false, true]) {
    final direction = download ? 'downloadData' : 'uploadData';
    test(
      '$direction retains transfer cleanup errors and their stacks',
      () async {
        final operationError = StateError('request failed');
        final operationStack = StackTrace.fromString('original request stack');
        final closeError = StateError('remote close failed');
        final closeStack = StackTrace.fromString('original close stack');
        final fileError = StateError('file cleanup failed');
        final fileStack = StackTrace.fromString('original file cleanup stack');
        final cleanup = DataSyncTransferFailure(
          commitState: DataSyncCommitState.notApplied,
          failures: [
            (stage: 'transfer', error: operationError, stack: operationStack),
            (stage: 'remote close', error: closeError, stack: closeStack),
            (stage: 'file cleanup', error: fileError, stack: fileStack),
          ],
        );
        Future<Res<bool>> failTransfer() async =>
            Error.throwWithStackTrace(cleanup, operationStack);
        if (download) {
          fixture.transfer.onDownload = failTransfer;
        } else {
          fixture.transfer.onUpload = failTransfer;
        }

        final sync = fixture.controller;
        final result = await (download
            ? sync.downloadData()
            : sync.uploadData());

        expect(result.error, isTrue);
        expect(result.failure, same(cleanup));
        expect(
          result.failure?.stackTrace.toString(),
          operationStack.toString(),
        );
        final retained = result.failure! as DataSyncTransferFailure;
        expect(retained.commitState, DataSyncCommitState.notApplied);
        expect(retained.failures, [
          (stage: 'transfer', error: operationError, stack: operationStack),
          (stage: 'remote close', error: closeError, stack: closeStack),
          (stage: 'file cleanup', error: fileError, stack: fileStack),
        ]);
        expect(result.errorMessage, cleanup.toString());
        expect(sync.statusSnapshot.lastError, result.errorMessage);
        expect(sync.isUploading, isFalse);
        expect(sync.isDownloading, isFalse);
      },
    );
  }
}
