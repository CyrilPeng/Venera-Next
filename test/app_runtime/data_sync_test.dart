import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/data_sync.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test(
    'application controller observes while stopped and releases on dispose',
    () async {
      final root = Directory.systemTemp.createTempSync('app-sync-owner-');
      final previousConnection = appdata.settings['webdav'];
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      App.dataPath = root.path;
      appdata.settings['webdav'] = ['https://example.com', '', ''];
      appdata.implicitData['webdavSyncMode'] = 'manual';
      appdata.implicitData['webdavSyncPending'] = false;
      final controller = createApplicationDataSync();
      final other = createApplicationDataSync();
      expect(controller, isNot(same(other)));
      other.dispose();
      try {
        await appdata.saveData();
        expect(controller.hasPendingChanges, isFalse);
        controller.start();
        controller.start();
        await appdata.saveData();
        expect(controller.hasPendingChanges, isTrue);
        appdata.implicitData['webdavSyncPending'] = false;
        controller.stop();
        ComicSourceManager().notifyStateChange();
        expect(controller.hasPendingChanges, isTrue);
        appdata.implicitData['webdavSyncPending'] = false;
        controller.dispose();
        ComicSourceManager().notifyStateChange();
        await appdata.saveData();
        expect(appdata.implicitData['webdavSyncPending'], isFalse);
      } finally {
        controller.dispose();
        await appdata.saveData(false);
        appdata.settings['webdav'] = previousConnection;
        appdata.implicitData.clear();
        appdata.implicitData.addAll(previousImplicit);
        root.deleteSync(recursive: true);
      }
    },
  );
}
