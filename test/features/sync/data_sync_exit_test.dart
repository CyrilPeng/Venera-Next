import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import '../../support/data_sync_fixture.dart';

void main() {
  test(
    'exit joins accepted upload and queued download while refusing new work',
    () async {
      final upload = Completer<Res<bool>>();
      final download = Completer<Res<bool>>();
      var downloads = 0;
      final f = SyncTestFixture();
      addTearDown(f.disposeController);
      f.transfer.onUpload = () => upload.future;
      f.transfer.onDownload = () {
        downloads++;
        return download.future;
      };
      final first = f.controller.uploadData();
      final second = f.controller.downloadData();
      final preparing = f.controller.prepareForExit();
      expect(identical(preparing, f.controller.prepareForExit()), isTrue);
      var ready = false;
      final releaseFuture = preparing.then((release) {
        ready = true;
        return release;
      });
      expect((await f.controller.uploadData()).error, isTrue);
      expect((await f.controller.downloadData()).error, isTrue);
      upload.complete(const Res(true));
      await first;
      await pumpEventQueue();
      expect(downloads, 1);
      expect(ready, isFalse);
      download.complete(const Res(false));
      await second;
      final release = await releaseFuture;
      expect(ready, isTrue);
      expect((await f.controller.downloadData()).error, isTrue);
      release();
      expect((await f.controller.downloadData()).success, isTrue);
    },
  );

  test(
    'accepted configuration can complete its required transfer behind exit barrier',
    () async {
      final upload = Completer<Res<bool>>();
      var uploads = 0;
      final f = SyncTestFixture();
      addTearDown(f.disposeController);
      f.transfer.onUpload = () {
        uploads++;
        return uploads == 1 ? upload.future : Future.value(const Res(true));
      };
      final first = f.controller.uploadData();
      final configuration = f.controller.configure(
        config: ['https://new.example/dav', 'u', 'p'],
        excludedFields: '',
        syncMode: DataSyncMode.scheduled,
        minutes: 30,
        initialUpload: true,
      );
      final preparing = f.controller.prepareForExit();
      final rejected = await f.controller.configure(
        config: [],
        excludedFields: '',
        syncMode: DataSyncMode.manual,
        minutes: 30,
        initialUpload: false,
      );
      expect(rejected.error, isTrue);
      upload.complete(const Res(true));
      await first;
      expect((await configuration).success, isTrue);
      final release = await preparing;
      expect(uploads, 2);
      release();
    },
  );

  test(
    'failed exit persistence releases admissions so preparation can retry',
    () async {
      var writes = 0;
      final f = SyncTestFixture(
        persistImplicit: () async {
          if (++writes == 1) throw StateError('save failed');
        },
      );
      addTearDown(f.disposeController);
      await expectLater(f.controller.prepareForExit(), throwsStateError);
      expect((await f.controller.uploadData()).success, isTrue);
      final release = await f.controller.prepareForExit();
      release();
    },
  );

  test('old release cannot unlock a newer exit preparation', () async {
    final f = SyncTestFixture();
    addTearDown(f.disposeController);
    final old = await f.controller.prepareForExit();
    old();
    final current = await f.controller.prepareForExit();
    old();
    expect((await f.controller.uploadData()).error, isTrue);
    current();
    current();
    expect((await f.controller.uploadData()).success, isTrue);
  });
}
