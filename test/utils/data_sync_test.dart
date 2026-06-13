import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  setUp(() {
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    Log.isMuted = true;
    appdata.implicitData['webdavAutoSync'] = false;
  });

  tearDown(() {
    appdata.implicitData['webdavAutoSync'] = false;
    Log.clear();
    Log.isMuted = false;
    DataSync.resetForTesting();
  });

  test(
    'uploadData coalesces concurrent uploads into one pending task',
    () async {
      final uploads = <Completer<Res<bool>>>[];
      DataSync.debugUploadOverride = () {
        final completer = Completer<Res<bool>>();
        uploads.add(completer);
        return completer.future;
      };

      final sync = DataSync();
      final first = sync.uploadData();
      final second = sync.uploadData();
      final third = sync.uploadData();
      var waitCompleted = false;
      final waitFuture = sync.debugWaitForUploadBeforeClose().then((_) {
        waitCompleted = true;
      });

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
    DataSync.debugUploadOverride = () => upload.future;
    DataSync.debugDownloadOverride = () async {
      downloadCount++;
      return const Res(true);
    };

    final sync = DataSync();
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
    DataSync.debugUploadOverride = () => upload.future;
    DataSync.debugDownloadOverride = () {
      downloadStarted = true;
      return download.future;
    };

    final sync = DataSync();
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
    DataSync.debugUploadOverride = () async {
      return const Res.error('upload failed');
    };

    final sync = DataSync();
    final result = await sync.uploadData();

    expect(result.error, isTrue);
    expect(result.errorMessage, 'upload failed');
    expect(sync.lastError, 'upload failed');
    expect(sync.statusSnapshot.lastError, 'upload failed');
    expect(sync.isUploading, isFalse);
  });

  test('downloadData converts thrown errors into failed results', () async {
    DataSync.debugDownloadOverride = () async {
      throw StateError('download failed');
    };

    final sync = DataSync();
    final result = await sync.downloadData();

    expect(result.error, isTrue);
    expect(result.errorMessage, contains('download failed'));
    expect(sync.lastError, result.errorMessage);
    expect(sync.isDownloading, isFalse);
  });
}
